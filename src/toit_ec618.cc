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

  // C++ static initializers (captured in linker script).
  extern void (*__init_array_start[])(void);
  extern void (*__init_array_end[])(void);
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

namespace toit {

// RAII guard that temporarily opens a write window inside the AP image
// area. The platform's sysROSpaceCheck override (sys_ro_override.c) consults
// toit_ap_image_modify_{start,end} to decide whether a write is allowed; the
// addresses are physical (non-XIP) flash offsets.
class AllowFirmwareModifications {
 public:
  AllowFirmwareModifications(uint32_t start, uint32_t end) {
    saved_start_ = toit_ap_image_modify_start;
    saved_end_ = toit_ap_image_modify_end;
    toit_ap_image_modify_start = start;
    toit_ap_image_modify_end = end;
  }
  ~AllowFirmwareModifications() {
    toit_ap_image_modify_start = saved_start_;
    toit_ap_image_modify_end = saved_end_;
  }

 private:
  uint32_t saved_start_;
  uint32_t saved_end_;
};

// Copies the staged firmware in FLASH_FOTA_REGION into the active image
// area, replacing the bytes after the unchanged prefix. The contents have
// already been hashed and validated by ota_end; this step is a plain
// erase-then-copy with no further verification. Returns true on success.
static bool perform_ota_commit() {
  extern uint32_t ota_commit_size;

  // Re-derive the prefix length from the running image instead of carrying
  // it forward as separate state. ota_write recorded ota_commit_size as the
  // total image size; everything past the prefix lives in FOTA.
  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  if (extension == null) {
    printf("[toit] ERROR: OTA commit: embedded extension is null\n");
    return false;
  }
  const uint32_t prefix_size =
      reinterpret_cast<uint32_t>(extension) - AP_FLASH_LOAD_ADDR;
  if (ota_commit_size <= prefix_size) {
    printf("[toit] ERROR: OTA commit: image too small for prefix\n");
    return false;
  }
  const uint32_t extension_size = ota_commit_size - prefix_size;

  // ota_write pads the staged tail to a 16-byte boundary, so the FOTA
  // region holds round-up(extension_size, 16) bytes. The copy below has to
  // move the same span over to the active image, because
  // BSP_QSPI_Write_Safe also requires 16-byte-aligned writes.
  const uint32_t SEGMENT = 16;
  const uint32_t SECTOR = 0x1000;
  const uint32_t aligned_size = (extension_size + SEGMENT - 1) & ~(SEGMENT - 1);

  // sysROSpaceCheck and BSP_QSPI_*_Safe both work in physical (non-XIP)
  // flash offsets, so convert from the XIP base.
  const uint32_t ap_image_physical = AP_FLASH_LOAD_ADDR - AP_FLASH_XIP_ADDR;
  const uint32_t dest_physical = ap_image_physical + prefix_size;

  AllowFirmwareModifications guard(dest_physical, dest_physical + aligned_size);

  // Erase the destination 4 KB sectors covering the staged area, rounding
  // up so a partial final sector is also erased before being written.
  const uint32_t erase_size = (aligned_size + SECTOR - 1) & ~(SECTOR - 1);
  for (uint32_t off = 0; off < erase_size; off += SECTOR) {
    if (BSP_QSPI_Erase_Safe(dest_physical + off, SECTOR) != QSPI_OK) {
      printf("[toit] ERROR: OTA erase failed at 0x%08x\n",
             static_cast<unsigned>(dest_physical + off));
      return false;
    }
  }

  // Copy via RAM buffer. BSP_QSPI_Read_Safe / Write_Safe disable XIP for
  // the duration of the call, so both the source and destination must live
  // in RAM. The Safe wrappers handle XIP toggling internally. Chunks are
  // sized in segment-aligned multiples so the trailing partial write is
  // also segment-aligned.
  static const uint32_t BUF_SIZE = 4096;
  uint8_t buf[BUF_SIZE];
  for (uint32_t off = 0; off < aligned_size; off += BUF_SIZE) {
    uint32_t chunk = aligned_size - off;
    if (chunk > BUF_SIZE) chunk = BUF_SIZE;
    if (BSP_QSPI_Read_Safe(buf, FLASH_FOTA_REGION_START + off, chunk) != QSPI_OK) {
      printf("[toit] ERROR: OTA read failed at 0x%08x\n",
             static_cast<unsigned>(FLASH_FOTA_REGION_START + off));
      return false;
    }
    if (BSP_QSPI_Write_Safe(buf, dest_physical + off, chunk) != QSPI_OK) {
      printf("[toit] ERROR: OTA write failed at 0x%08x\n",
             static_cast<unsigned>(dest_physical + off));
      return false;
    }
  }
  return true;
}

static void run_static_initializers() {
  for (void (**fn)(void) = __init_array_start; fn < __init_array_end; fn++) {
    (*fn)();
  }
}

static uint8 sleep_vote_handle = 0;

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

extern "C" __attribute__((used))
void toit_hardfault_dump(uint32_t* frame, uint32_t exc_return) {
  volatile uint32_t* const SCB_CFSR  = reinterpret_cast<uint32_t*>(0xE000ED28);
  volatile uint32_t* const SCB_HFSR  = reinterpret_cast<uint32_t*>(0xE000ED2C);
  volatile uint32_t* const SCB_MMFAR = reinterpret_cast<uint32_t*>(0xE000ED34);
  volatile uint32_t* const SCB_BFAR  = reinterpret_cast<uint32_t*>(0xE000ED38);
  printf("\n[HARDFAULT]\n");
  printf("  PC =0x%08x  LR =0x%08x  PSR=0x%08x\n",
         static_cast<unsigned>(frame[6]),
         static_cast<unsigned>(frame[5]),
         static_cast<unsigned>(frame[7]));
  printf("  R0 =0x%08x  R1 =0x%08x  R2 =0x%08x  R3 =0x%08x  R12=0x%08x\n",
         static_cast<unsigned>(frame[0]),
         static_cast<unsigned>(frame[1]),
         static_cast<unsigned>(frame[2]),
         static_cast<unsigned>(frame[3]),
         static_cast<unsigned>(frame[4]));
  printf("  EXC_RETURN=0x%08x\n", static_cast<unsigned>(exc_return));
  printf("  CFSR =0x%08x  HFSR=0x%08x\n",
         static_cast<unsigned>(*SCB_CFSR),
         static_cast<unsigned>(*SCB_HFSR));
  printf("  MMFAR=0x%08x  BFAR=0x%08x\n",
         static_cast<unsigned>(*SCB_MMFAR),
         static_cast<unsigned>(*SCB_BFAR));
  // Busy-wait so the UART can drain the dump before we reset — the
  // scheduler is not trustworthy from a fault context.
  for (volatile uint32_t i = 0; i < 2000000; i++) { /* spin */ }
  // SCB->AIRCR = VECTKEY (0x05FA << 16) | SYSRESETREQ (bit 2).
  volatile uint32_t* const SCB_AIRCR = reinterpret_cast<uint32_t*>(0xE000ED0C);
  *SCB_AIRCR = (0x05FAu << 16) | (1u << 2);
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

static void start() {
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

  // Install a RAM-resident vector table so we can intercept HardFault,
  // print a register dump, and reset cleanly — otherwise the SDK
  // silently resets the chip with no diagnostic output.
  install_hardfault_dumper();

  // Vote against sleep1 during execution so the scheduler tick keeps running.
  slpManApplyPlatVoteHandle("toit", &sleep_vote_handle);
  slpManPlatVoteDisableSleep(sleep_vote_handle, SLP_SLP1_STATE);

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
  }

  GcMetadata::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();

  // Check if an OTA update was staged during execution.
  extern bool ota_updated;
  if (ota_updated) {
    ota_updated = false;
    printf("[toit] INFO: OTA update staged — committing\n");
    if (perform_ota_commit()) {
      printf("[toit] INFO: OTA commit complete — rebooting\n");
    } else {
      printf("[toit] ERROR: OTA commit failed — active image may be corrupt\n");
    }
    RtcMemory::invalidate();
    slpManDeepSlpTimerStart(DEEPSLP_TIMER_ID0, 1000);
    // Fall through to sleep.
  }

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
      printf("[toit] INFO: entering deep sleep without wakeup timer\n");
      break;
    }

    case Scheduler::EXIT_NONE: {
      UNREACHABLE();
    }
  }

  // Re-enable sleep voting and let FreeRTOS put the system to sleep.
  RtcMemory::on_deep_sleep_start();
  slpManPlatVoteEnableSleep(sleep_vote_handle, SLP_SLP1_STATE);

  // Disable the modem before sleeping. The PS stack holds votes that
  // block sleep entry; appSetCFUN(0) releases them synchronously.
  appSetCFUN(0);

  // Use HIBERNATE for all deep sleep cases. SLP2 does not reliably
  // preserve ASMB noinit data on this platform — the save/restore
  // mechanism corrupts user data. HIBERNATE wakes reliably via the
  // deep sleep timer after appSetCFUN(0) releases PS stack votes.
  // RTC memory is backed by flash (saved before sleep, restored on boot).
  apmuSetDeepestSleepMode(AP_STATE_HIBERNATE);

  // Switch the PS stack to power-saver mode.
  soc_power_mode(3, 0);

  // Enter idle loop — FreeRTOS tickless idle will enter deep sleep.
  while (true) {
    osDelay(10000);
  }
}

}  // namespace toit

extern "C" void toit_start() {
  toit::start();
}

#endif  // TOIT_EC618
