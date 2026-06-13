// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "top.h"

#ifdef TOIT_EC618

#include <stdio.h>
#include <string.h>  // memcpy (active-slot VM .data load).

extern "C" {
  #include "cmsis_os2.h"
  #include "flash_rt.h"
  #include "mem_map.h"
  #include "reset.h"
  #include "slpman.h"
  #include "plat_config.h"
  #include "apmu_external.h"

  // Writable window for flash operations against the AP image, consulted by
  // sysROSpaceCheck (overridden in sys_ro_override.c).
  extern uint32_t toit_ap_image_modify_start;
  extern uint32_t toit_ap_image_modify_end;

  // From ps_lib_api.h — declared here to avoid pulling in networkmgr dependencies.
  void appSetCFUN(int cfun);

  // From libcore_airm2m.a. Flips the PS stack into power-saver mode,
  // which is required for the PMU to actually transition to SLP2 or
  // HIBERNATE. slpManSetPmuSleepMode only sets a ceiling — it does not
  // release the PS stack's sleep votes. main=3 is LUAT_PM_POWER_MODE_POWER_SAVER.
  int soc_power_mode(uint8_t main, uint8_t sub);

  // VM-side C++ static initializers. The linker script splits the
  // init_array between PLAT (.load_dram_shared, used by PLAT startup)
  // and the active VM slot. Each slot's run_static_initializers()
  // iterates only its own slot's init_array, so PLAT does not have to
  // know which slot is active.
  extern void (*__vm_init_array_start[])(void);
  extern void (*__vm_init_array_end[])(void);

  // Slot geometry + the slot the dispatcher booted (set in toit_main.c).
  extern uint8_t toit_booted_slot;
  extern uint32_t __vm_a_start[];
  extern uint32_t __vm_b_start[];
  // The neutral base the VM image is linked at (NEITHER slot). The shared .data
  // slot pointers are link-base-relative, so they relocate to the booted slot.
  extern uint32_t __vm_link_base[];

  // The VM's writable-.data init image lives in RAM at [__vm_data_start,
  // __vm_data_end) (the linker bracket inside .load_dram_shared). PLAT loads it
  // from the base LMA at startup; load_active_slot_vm_data() overwrites it with
  // the ACTIVE slot's own per-slot copy before the slot pointers are relocated.
  extern uint8_t __vm_data_start[];
  extern uint8_t __vm_data_end[];

  // Generated table (toit_data_reloc.c): RAM addresses of the writable .data
  // words that hold VM-slot pointers, fixed up per-slot in start().
  extern const uint32_t toit_data_reloc[];
  extern const uint32_t toit_data_reloc_count;
}

#include "embedded_data.h"
#include "flash_registry.h"
#include "sha.h"
#include "heap.h"
#include "memory.h"
#include "messaging.h"
#include "os.h"
#include "process.h"
#include "program.h"
#include "rtc_memory_ec618.h"
#include "scheduler.h"
#include "vm.h"
#include "third_party/dartino/gc_metadata.h"

#include "slot_marker.h"
#include "slot_reloc_ec618.h"

namespace toit {

// Defined in primitive_ec618.cc. Hard Cortex-M reset (SCB SYSRESETREQ); does
// not return. Used to reboot into a freshly staged VM slot.
[[noreturn]] void ec618_system_reset();

static void run_static_initializers() {
  for (void (**fn)(void) = __vm_init_array_start; fn < __vm_init_array_end; fn++) {
    (*fn)();
  }
}

static uint8 sleep_vote_handle = 0;

// Deep-sleep-path hooks into VM drivers (see the sleep path below).
extern "C" bool toit_uart_sleep_vote_release_for_sleep();  // uart_ec618.cc.
extern "C" void toit_watchdog_presleep();                  // primitive_ec618.cc.
extern "C" int toit_capture_boot_wakeup_src();             // primitive_ec618.cc.

// Callback for deep sleep timer expiration. Must be registered for
// slpManDeepSlpTimerStart to work. The ID is ignored — the wake-up
// itself is the important part.
static void deep_sleep_timer_cb(uint8_t id) {
  (void)id;
}

// On a HardFault, dump the exception frame + Cortex-M3 fault status
// registers over printf, drain the UART, and trigger a system reset.
// The SDK's HardFault handler is a static symbol pointed to from the
// .isr_vector table, so we can't replace it by linker symbol; instead
// we install a RAM-resident vector table via VTOR relocation and patch
// entry 3 with our handler. Without this, the SDK's handler resets the
// chip immediately with no visible information, leaving silent reboots.

// The fault path emits via putchar() rather than printf(): printf pulls in
// vfprintf and its integer formatter, a lot of code to run from a fault context
// while diagnosing a possibly mis-relocated slot. putchar is on the VM->PLAT
// wrap list (tools/ec618/plat_jt_ldflags.lua), so it routes through the slot's
// jump-table stub and stays position-independent in either slot.
static void hf_puts(const char* s) {
  while (*s != '\0') putchar(*s++);
}

static void hf_hex(uint32_t v) {
  for (int shift = 28; shift >= 0; shift -= 4) {
    int nibble = (v >> shift) & 0xf;
    putchar(nibble < 10 ? '0' + nibble : 'a' + nibble - 10);
  }
}

extern "C" __attribute__((used))
void toit_hardfault_dump(uint32_t* frame, uint32_t exc_return) {
  const uint32_t cfsr  = *reinterpret_cast<volatile uint32_t*>(0xE000ED28);
  const uint32_t hfsr  = *reinterpret_cast<volatile uint32_t*>(0xE000ED2C);
  const uint32_t mmfar = *reinterpret_cast<volatile uint32_t*>(0xE000ED34);
  const uint32_t bfar  = *reinterpret_cast<volatile uint32_t*>(0xE000ED38);
  // The exception stacked R0-R3, R12, LR, PC, PSR at `frame`. Validate that the
  // pointer lands in one of the two SRAM windows before dereferencing it: a
  // corrupt / overflowed stack would otherwise double-fault right here and lock
  // up — the exact silent hang this dump exists to replace.
  const uintptr_t f = reinterpret_cast<uintptr_t>(frame);
  const bool frame_ok =
      (f >= 0x00000100 && f + 32u <= 0x00010000) ||   // ASMB 64 KB
      (f >= 0x00400000 && f + 32u <= 0x00540000);     // MSMB 1.25 MB
  const uint32_t pc  = frame_ok ? frame[6] : 0;
  const uint32_t lr  = frame_ok ? frame[5] : 0;
  const uint32_t psr = frame_ok ? frame[7] : 0;
  hf_puts("\n[HARDFAULT] PC="); hf_hex(pc);
  hf_puts(" LR=");              hf_hex(lr);
  hf_puts(" PSR=");             hf_hex(psr);
  hf_puts(frame_ok ? "\n" : " (bad frame)\n");
  hf_puts("  EXC_RETURN=");     hf_hex(exc_return);
  hf_puts(" CFSR=");            hf_hex(cfsr);
  hf_puts(" HFSR=");            hf_hex(hfsr);
  hf_puts(" MMFAR=");           hf_hex(mmfar);
  hf_puts(" BFAR=");            hf_hex(bfar);
  hf_puts("\n  resetting (a faulting trial slot rolls back on the next boot)\n");
  // Let the UART drain, then reset. Resetting (rather than spinning) is what
  // lets the dispatcher roll a crashing TRIAL slot back to the known-good one.
  for (volatile uint32_t i = 0; i < 2000000; i++) { /* spin */ }
  // SCB->AIRCR = VECTKEY (0x05FA << 16) | SYSRESETREQ (bit 2).
  *reinterpret_cast<volatile uint32_t*>(0xE000ED0C) = (0x05FAu << 16) | (1u << 2);
  while (1) { /* unreachable */ }
}

extern "C" __attribute__((naked, used))
void toit_hardfault_entry(void) {
  __asm volatile (
    "tst lr, #4              \n"  // EXC_RETURN bit 2: 0=MSP, 1=PSP
    "ite eq                  \n"
    "mrseq r0, msp           \n"
    "mrsne r0, psp           \n"
    "mov  r1, lr             \n"
    "b    toit_hardfault_dump \n"
  );
}

// RAM-resident vector table (256-byte aligned, room for all 80 vectors
// the SDK's table holds — we just copy and patch).
static __attribute__((aligned(256))) uint32_t toit_ram_vectors[80];

static void install_hardfault_dumper() {
  volatile uint32_t* const SCB_VTOR = reinterpret_cast<uint32_t*>(0xE000ED08);
  const uint32_t* current = reinterpret_cast<const uint32_t*>(*SCB_VTOR);
  for (size_t i = 0; i < sizeof(toit_ram_vectors) / sizeof(toit_ram_vectors[0]); i++) {
    toit_ram_vectors[i] = current[i];
  }
  // Patch HardFault (vector index 3). C function pointer is already
  // thumb-tagged.
  extern void toit_hardfault_entry(void);
  toit_ram_vectors[3] = reinterpret_cast<uint32_t>(&toit_hardfault_entry);
  *SCB_VTOR = reinterpret_cast<uint32_t>(toit_ram_vectors);
}

static const char* last_reset_name(LastResetState_e s) {
  switch (s) {
    case LAST_RESET_POR:       return "POR";
    case LAST_RESET_NORMAL:    return "NORMAL(sleep)";
    case LAST_RESET_SWRESET:   return "SWRESET";
    case LAST_RESET_HARDFAULT: return "HARDFAULT";
    case LAST_RESET_ASSERT:    return "ASSERT";
    case LAST_RESET_WDTSW:     return "WDTSW";
    case LAST_RESET_WDTHW:     return "WDTHW";
    case LAST_RESET_LOCKUP:    return "LOCKUP";
    case LAST_RESET_AONWDT:    return "AONWDT";
    case LAST_RESET_BATLOW:    return "BATLOW";
    case LAST_RESET_TEMPHI:    return "TEMPHI";
    case LAST_RESET_FOTA:      return "FOTA";
    case LAST_RESET_CPRESET:   return "CPRESET";
    default:                   return "UNKNOWN";
  }
}

// The VM's writable .data (.load_dram_shared) is loaded ONCE by PLAT from a
// fixed flash image — the data-init linked at the neutral __vm_link_base — and
// the per-slot SRL1 relocation only ever touches the slot itself, never this
// shared RAM. So every VM-slot pointer that lives in .data — the interpreter's
// computed-goto dispatch_table and the per-module *_primitives_ tables (see
// toit_data_reloc.c) — is baked at the link base. On EVERY boot they point at
// the link base, not the booted slot, so the interpreter would run the wrong
// code (and an OTA writing the booted slot could erase code it is executing).
// Shift them by the slot displacement here, before any static initializer or
// the interpreter reads them. Because the link base is NEITHER slot, delta is
// non-zero on both slot A and slot B (the slot-A relocation is no longer a
// no-op); it is only zero if the link base is set back to a real slot. This
// function itself touches no .data slot pointer, so it is safe to run first.
// Loads the ACTIVE slot's OWN VM .data init image over the base-loaded RAM.
//
// PLAT loads .load_dram_shared once from the base image's fixed LMA — i.e. slot
// A's VM .data. But the VM's writable .data (dispatch_table, *_primitives_, and
// any mutable VM globals) differs between firmware builds, so a slot-B firmware
// that differs from slot A would boot with slot A's values and fault (the
// A!=B OTA bug). Each slot now ships its OWN .data init image, carried verbatim
// right after its body+extension (slot offset == body_size; see
// slot_reloc_ec618.h / docs/ota-contract.md). Copy the booted slot's copy into
// [__vm_data_start, __vm_data_end) BEFORE relocate_data_slot_pointers() shifts
// the (still link-base) slot pointers. A no-op for legacy images with no data
// region (data_size == 0).
static void load_active_slot_vm_data() {
  const uint8_t* active = reinterpret_cast<const uint8_t*>(
      (toit_booted_slot == 'B') ? __vm_b_start : __vm_a_start);
  const uint32_t slot_size = reinterpret_cast<uint32_t>(__vm_b_start) -
                             reinterpret_cast<uint32_t>(__vm_a_start);
  SlotRelocTable table;
  if (!slot_reloc_parse_trailer(active, slot_size, &table)) {
    printf("[toit] WARN: active slot has no reloc trailer; VM .data not per-slot\n");
    return;
  }
  if (table.data_size == 0) return;  // Legacy image: the base-loaded .data stands.
  const uint32_t expected = reinterpret_cast<uint32_t>(__vm_data_end) -
                            reinterpret_cast<uint32_t>(__vm_data_start);
  if (table.data_size != expected) {
    // A build inconsistency: refuse to copy rather than overrun the .data region.
    printf("[toit] ERROR: VM .data size mismatch carried=0x%x linker=0x%x — skipping copy\n",
           static_cast<unsigned>(table.data_size), static_cast<unsigned>(expected));
    return;
  }
  // The .data init rides at slot offset body_size (right after body+extension).
  memcpy(__vm_data_start, active + table.body_size, table.data_size);
}

static void relocate_data_slot_pointers() {
  const uint32_t link_base = reinterpret_cast<uint32_t>(__vm_link_base);
  const uint32_t active_base = (toit_booted_slot == 'B')
      ? reinterpret_cast<uint32_t>(__vm_b_start)
      : reinterpret_cast<uint32_t>(__vm_a_start);
  const int32_t delta = static_cast<int32_t>(active_base) -
                        static_cast<int32_t>(link_base);
  if (delta == 0) return;
  for (uint32_t i = 0; i < toit_data_reloc_count; i++) {
    uint32_t* p = reinterpret_cast<uint32_t*>(toit_data_reloc[i]);
    *p = static_cast<uint32_t>(*p + delta);
  }
}

static void start() {
  // Load the booted slot's OWN VM .data init image (overriding the base image's
  // slot-A copy), THEN fix that .data's VM-slot pointers for the booted slot —
  // both BEFORE anything (static constructors, the interpreter) reads .data.
  load_active_slot_vm_data();
  relocate_data_slot_pointers();

  // Run C++ static initializers (the linker script must capture .init_array).
  run_static_initializers();

  // Log the previous reset reason. After a HardFault dump-and-reset
  // (see toit_hardfault_dump below) this prints "ap=HARDFAULT", but it
  // also catches watchdog/lockup/assert/POR resets that bypass our
  // handler.
  {
    LastResetState_e ap = LAST_RESET_UNKNOWN;
    LastResetState_e cp = LAST_RESET_UNKNOWN;
    ResetStateGet(&ap, &cp);
    printf("[toit] INFO: last reset ap=%s cp=%s\n",
           last_reset_name(ap), last_reset_name(cp));
  }

  // Snapshot the sleep-manager wake source NOW: it reads correctly only this
  // early — the sleep-manager re-init below resets it to POR before app code
  // (ec618.wakeup-cause) can read it (HW-verified). slpManGetLastSlpState()
  // corroborates: 4 (HIBERNATE) after a deep-sleep wake, 0 after a cold or
  // watchdog boot.
  int wakeup_src = toit_capture_boot_wakeup_src();
  printf("[toit] DEBUG: wake src=%d last_slp_state=%d\n",
         wakeup_src, static_cast<int>(slpManGetLastSlpState()));

  // Install a RAM-resident vector table so we can intercept HardFault,
  // print a register dump, and reset cleanly — otherwise the SDK
  // silently resets the chip with no diagnostic output.
  install_hardfault_dumper();

  // Vote against sleep1 during execution so the scheduler tick keeps running.
  // OPEN QUESTION (idle-deafness post-mortem, docs/ec618-known-issues.md #10):
  // this vote should have made SLEEP1 impossible while the VM runs, yet idle
  // SLEEP1 demonstrably happened (it killed armed uart0 DMA receives) until
  // the UART driver added its own, late-applied vote. Suspect: applying a
  // vote handle this early in boot fails. Log the codes to settle it.
  slpManRet_t vote_apply = slpManApplyPlatVoteHandle("toit", &sleep_vote_handle);
  slpManRet_t vote_disable = slpManPlatVoteDisableSleep(sleep_vote_handle, SLP_SLP1_STATE);
  printf("[toit] DEBUG: sleep vote apply=%d disable=%d handle=%u allow=%d\n",
         static_cast<int>(vote_apply), static_cast<int>(vote_disable),
         static_cast<unsigned>(sleep_vote_handle),
         static_cast<int>(slpManPlatGetSlpState()));

  // Set max sleep state to sleep2 (deep sleep with RAM preservation).
  slpManSetPmuSleepMode(true, SLP_SLP2_STATE, false);

  // Register a wake-up callback for all deep sleep timers. Without this,
  // slpManDeepSlpTimerStart silently fails.
  for (uint8_t i = 0; i <= DEEPSLP_TIMER_ID6; i++) {
    slpManDeepSlpTimerRegisterExpCb((slpManTimerID_e)i, deep_sleep_timer_cb);
  }

  // Initialize subsystems.
  RtcMemory::set_up();
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();
  extern void set_up_mbedtls_threading();
  set_up_mbedtls_threading();

  // Set fault action to reset after platform init is done. Setting it
  // earlier causes bootloops because the PS stack hits transient
  // assertions during startup that resolve on their own.
  BSP_SetPlatConfigItemValue(PLAT_CONFIG_ITEM_FAULT_ACTION, 1);

  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  if (extension == null || extension->images() == 0) {
    FATAL("no embedded program found");
  }
  EmbeddedImage boot = extension->image(0);
  const Program* program = boot.program;

  Scheduler::ExitState exit_state;
  { VM vm;
    vm.load_platform_event_sources();
    create_and_start_external_message_handlers(&vm);
    int group_id = vm.scheduler()->next_group_id();
    exit_state = vm.scheduler()->run_boot_program(const_cast<Program*>(program), group_id);

    printf("[toit] INFO: VM exited (reason=%d)\n", static_cast<int>(exit_state.reason));

    // A dual-slot OTA stages the new slot via slot_stage (FirmwareWriter.commit)
    // and asks to reboot into it through firmware.upgrade, which exits the VM via
    // deep sleep. Mirror the ESP32 run loop (toit_esp32.cc): when the OTA staged a
    // slot (marker state NEW — the analogue of ESP32's boot partition changing),
    // do a hard chip reset so the dispatcher (toit_main.c) trial-boots the staged
    // slot, exactly like ESP32 calls esp_restart() on a firmware update. Done here
    // — before the VM destructor and OS::tear_down() — because EC618's external
    // handler teardown can block; a firmware-update reset needs no clean shutdown.
    {
      slot_record marker;
      slot_marker_read(&marker);
      if (marker.state == SLOT_STATE_NEW) {
        printf("[toit] INFO: firmware updated; resetting into staged slot %c\n",
               marker.pending);
        ec618_system_reset();  // Does not return.
      }
    }
  }

  GcMetadata::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();

  switch (exit_state.reason) {
    case Scheduler::EXIT_DEEP_SLEEP: {
      const int64 MIN_MS = 1000;       // Deep-sleep timer minimum is ~1s on EC618.
      const int64 MAX_MS = 2 * 60 * 60 * 1000;  // 2 hours.
      int64 ms = exit_state.value;
      if (ms < MIN_MS) ms = MIN_MS;
      else if (ms > MAX_MS) ms = MAX_MS;
      printf("[toit] INFO: entering deep sleep for %dms\n", static_cast<int>(ms));
      RtcMemory::adjust_wakeup_time_before_sleep(ms);
      slpManDeepSlpTimerStart(DEEPSLP_TIMER_ID0, ms);
      break;
    }

    case Scheduler::EXIT_ERROR: {
      printf("[toit] WARN: entering deep sleep for 1s due to error\n");
      RtcMemory::adjust_wakeup_time_before_sleep(1000);
      slpManDeepSlpTimerStart(DEEPSLP_TIMER_ID0, 1000);
      break;
    }

    case Scheduler::EXIT_DONE: {
#if CONFIG_TOIT_EC618_RESET_ON_VM_EXIT
      // Deep-sleeping with no wakeup timer would leave the device dead until an
      // external reset (impossible on a no-remote-reset rig; the watchdogs are
      // gated while asleep). Reset instead so the device reboots straight back
      // into the boot program and self-recovers. Only reached on a full-VM exit
      // (e.g. a crash that brings the whole VM down), not on normal operation.
      printf("[toit] INFO: VM done; resetting to recover (RESET_ON_VM_EXIT)\n");
      ec618_system_reset();  // Does not return.
#else
      printf("[toit] INFO: entering deep sleep without wakeup timer\n");
#endif
      break;
    }

    case Scheduler::EXIT_NONE: {
      UNREACHABLE();
    }
  }

  // Re-enable sleep voting and let FreeRTOS put the system to sleep.
  RtcMemory::on_deep_sleep_start();
  slpManPlatVoteEnableSleep(sleep_vote_handle, SLP_SLP1_STATE);

  // A port still open at VM exit (the test agent's console port, say) keeps
  // the UART driver's SLEEP1 veto held — containers are not torn down on a
  // deep-sleep exit, and that vote blocks hibernate forever. Deep sleep ends
  // in a reboot, so in-flight UART state is moot: release it here.
  bool uart_vote_was_held = toit_uart_sleep_vote_release_for_sleep();
  printf("[toit] DEBUG: pre-sleep: uart sleep vote held=%d\n",
         uart_vote_was_held ? 1 : 0);

  // Re-arm the software watchdog as a 120 s backstop: its stale deadline
  // would otherwise fire while we wait for sleep entry (observed: a FATAL
  // reset 60 s after the last feed, masquerading as the deep-sleep wake).
  // A successful hibernate kills it; a blocked entry still self-recovers.
  toit_watchdog_presleep();

  // Disable the modem before sleeping. The PS stack holds votes that
  // block sleep entry; appSetCFUN(0) releases them synchronously.
  appSetCFUN(0);

  // Power off the AON IO LDO for the sleep. Toit has no pin-hold API yet
  // (the ESP32 port's deep-sleep pin holds have no counterpart here, and
  // pins are torn down with their container anyway), so an AON pad cannot
  // be used *correctly* across deep sleep — a held level would be unowned
  // state. Until holds exist, the rail goes down (all AON IOs drop low,
  // the wakeup pads are on a separate domain and keep working); the GPIO
  // driver powers it back up when an AON pad is opened after the wake.
  slpManAONIOPowerOff();

  // Use HIBERNATE for all deep sleep cases. SLP2 does not reliably
  // preserve ASMB noinit data on this platform — the save/restore
  // mechanism corrupts user data. HIBERNATE wakes reliably via the
  // deep sleep timer after appSetCFUN(0) releases PS stack votes.
  // RTC memory is backed by flash (saved before sleep, restored on boot).
  apmuSetDeepestSleepMode(AP_STATE_HIBERNATE);

  // Switch the PS stack to power-saver mode.
  soc_power_mode(3, 0);

#if CONFIG_TOIT_EC618_VM_WATCHDOG
  // Stop the platform's always-on (AON) watchdog before hibernating: the CP
  // — which auto-feeds it during normal operation — stops in hibernate while
  // the AON domain keeps counting, so left running it would reset the chip
  // ~20s into deep sleep. The wake reboot re-arms it (boot ROM) and the CP
  // resumes feeding. Doing this last — after the teardown above — means a
  // wedged shutdown is still caught.
  slpManAonWdtStop();
#endif

  // The CMSIS peripheral drivers hold PER-DRIVER sleep votes
  // (slpManDrvVoteSleep), a mechanism separate from the plat vote handles
  // that slpManPlatGetSlpState() reports. The always-open console UART (and
  // its DMA) vote at most SLP1 when idle — capping the achievable state
  // below HIBERNATE no matter what the plat votes allow. Deep sleep ends in
  // a reboot, so release every driver vote to HIB before idling.
  for (int m = 0; m < SLP_VOTE_MAX_NUM; m++) {
    slpManDrvVoteSleep(static_cast<slpDrvVoteModule_t>(m), SLP_HIB_STATE);
  }

  // Enter idle loop — FreeRTOS tickless idle will enter deep sleep.
  // allow = deepest state the PLAT votes permit; last = the state actually
  // entered on the previous tickless idle (0=active 1=idle 2=slp1 3=slp2
  // 4=hib). On a healthy hibernate entry the chip reboots before a second
  // line; repeated lines mean entry is blocked and `last` says how deep it
  // got.
  while (true) {
    printf("[toit] DEBUG: pre-sleep: allow=%d last=%d\n",
           static_cast<int>(slpManPlatGetSlpState()),
           static_cast<int>(slpManGetLastSlpState()));
    osDelay(10000);
  }
}

}  // namespace toit

extern "C" void toit_start() {
  toit::start();
}

// Slot entry pointer. Lives at the very start of the VM slot (.vm_entry
// is placed first inside .vm_a / .vm_b by the linker script). The
// PLAT-side dispatcher in toit_main.c reads this word from the active
// slot's base address and tail-calls through it. The linker handles the
// Thumb-bit on the relocation for us, so the value the dispatcher reads
// is directly usable as a function pointer.
extern "C" __attribute__((section(".vm_entry"), used))
void (* const toit_vm_entry)(void) = &toit_start;

#endif  // TOIT_EC618
