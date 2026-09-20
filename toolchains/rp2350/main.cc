// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "pico/stdlib.h"
#include "pico/bootrom.h"
#include "pico/low_power.h"
#include "pico/stdio_usb.h"
#include "boot/picoboot_constants.h"
#include "hardware/powman.h"
#include "hardware/watchdog.h"
#include "hardware/structs/scb.h"
#include "hardware/structs/systick.h"
#include "hardware/flash.h"
// Pico uses this macro for the 256-byte programming unit. Toit uses the
// same name for its 4096-byte allocation page constant.
#undef FLASH_PAGE_SIZE
#include "FreeRTOS.h"
#include "task.h"
#include "embedded_data.h"
#include "entropy_mixer.h"
#include "flash_registry.h"
#include "memory.h"
#include "messaging.h"
#include "os.h"
#include "program.h"
#include "power_rp2350.h"
#include "scheduler.h"
#include "vm.h"
#include "watchdog_rp2350.h"

#ifdef TOIT_RP2350_TEST_FAULT
void schedule_rp2350_failure_test();
#endif

// Protect all newlib allocation entry points, including memalign and the
// internal _malloc_r calls which bypass Pico's malloc wrapper. This is a
// single-core port: suspending scheduling is recursive and also composes with
// FreeRTOS heap_3. No interrupt handler may allocate memory.
extern "C" void __malloc_lock(struct _reent*) { vTaskSuspendAll(); }
extern "C" void __malloc_unlock(struct _reent*) { xTaskResumeAll(); }

namespace toit {
extern void set_up_mbedtls_threading();
static uint8_t flash_id[4];

[[noreturn]] static void enter_deep_sleep(int64 milliseconds) {
  boot_info_t info;
  if (rom_get_boot_info(&info) &&
      (info.tbyb_and_update_info & BOOT_TBYB_AND_UPDATE_FLAG_BUY_PENDING)) {
    // Defend the ROM trial even if code bypasses the public library guard.
    // Powering off would stop its watchdog and lose the rollback deadline.
    panic("Cannot enter deep sleep during a firmware trial");
  }
  if (milliseconds < 1000) milliseconds = 1000;
  if (milliseconds > INT64_MAX / 1000) panic("Deep sleep duration too large");

  // USB teardown includes a timed wait and can request a FreeRTOS context
  // switch. Complete it while the scheduler and interrupts still work.
  // The generic SDK pstate helper performs this teardown internally, so we
  // use the POWMAN primitives directly after the final interrupt shutdown.
  stdio_flush();
  stdio_usb_deinit();

  // No Toit threads remain. Stop the RTOS tick and interrupt wakeups too:
  // masking interrupts with PRIMASK alone does not prevent WFI from waking.
  save_and_disable_interrupts();
  systick_hw->csr = 0;
  scb_hw->icsr = M33_ICSR_PENDSTCLR_BITS | M33_ICSR_PENDSVCLR_BITS;
  for (unsigned i = 0; i < (NUM_IRQS + 31) / 32; i++) {
    nvic_hw->icer[i] = UINT32_MAX;
    nvic_hw->icpr[i] = UINT32_MAX;
  }
  watchdog_disable();
  powman_disable_all_wakeups();
  powman_timer_stop();
  prepare_rp2350_time_for_sleep();
  powman_timer_set_ms(0);
  powman_timer_set_1khz_tick_source_lposc();
  powman_timer_start();
  powman_set_debug_power_request_ignored(true);
  powman_set_bits(&powman_hw->vreg_ctrl, POWMAN_VREG_CTRL_UNLOCK_BITS);

  pstate_bitset_t retained = pstate_bitset_none();
  low_power_persistent_pstate_get(&retained);
  powman_power_state sleep_state = pstate_bitset_to_powman_power_state(&retained);
  if (!powman_configure_wakeup_state(sleep_state, powman_get_power_state())) {
    panic("Invalid RP2350 deep sleep power state");
  }
  // Use the SDK's retained-data initialization on wake, but no saved code
  // pointer: ROM must select the firmware normally on every boot.
  for (unsigned i = 0; i < 4; i++) powman_hw->boot[i] = 0;
  powman_hw->scratch[6] = sleep_state;
  powman_hw->scratch[7] = 0;
  powman_enable_alarm_wakeup_at_ms(milliseconds);
  int error = powman_set_power_state(sleep_state);
  if (error != PICO_OK) panic("RP2350 deep sleep failed: %d", error);
  __dsb();
  for (;;) __wfi();
}

static void run_vm(void*) {
  // Give the USB host time to reconnect after flashing/reset.
  vTaskDelay(pdMS_TO_TICKS(2000));
  printf("[toit] RP2350 VM starting\n");
  printf("[toit] flash JEDEC %02x%02x%02x\n", flash_id[1], flash_id[2], flash_id[3]);
  boot_info_t boot_info;
  if (rom_get_boot_info(&boot_info)) {
    printf("[toit] boot partition=%d type=%u trial/update=%u\n",
        boot_info.partition, boot_info.boot_type, boot_info.tbyb_and_update_info);
#ifdef TOIT_RP2350_TEST_FAULT
    if (boot_info.tbyb_and_update_info & BOOT_TBYB_AND_UPDATE_FLAG_BUY_PENDING) {
      schedule_rp2350_failure_test();
    }
#endif
  }
  OS::set_up();
  FlashRegistry::set_up();
  ObjectMemory::set_up();
  set_up_mbedtls_threading();
  EntropyMixer::instance()->set_up();
  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  if (extension == null || extension->images() < 1) FATAL("missing boot image");
  auto program = const_cast<Program*>(extension->image(0).program);
  if (!program->is_valid_embedded()) FATAL("invalid boot image");
  Scheduler::ExitState result;
  {
    VM vm;
    vm.load_platform_event_sources();
    create_and_start_external_message_handlers(&vm);
    result = vm.scheduler()->run_boot_program(program, vm.scheduler()->next_group_id());
    printf("[toit] VM exited: reason=%d value=%lld\n", result.reason, static_cast<long long>(result.value));
  }
  printf("[toit] VM teardown complete\n");
  if (result.reason == Scheduler::EXIT_DEEP_SLEEP) {
    enter_deep_sleep(result.value);
  }
  if (result.reason == Scheduler::EXIT_RESET || result.reason == Scheduler::EXIT_ERROR) {
    // A normal reboot rejects an unconfirmed trial. Confirmed firmware retries
    // its system startup, matching the existing embedded ports' error path.
    uint32_t delay_ms = result.reason == Scheduler::EXIT_ERROR ? 1000 : 10;
    rom_reboot(REBOOT2_FLAG_REBOOT_TYPE_NORMAL | REBOOT2_FLAG_NO_RETURN_ON_SUCCESS,
        delay_ms, BOOT_PARTITION_NONE, 0);
  }
  for (;;) vTaskDelay(pdMS_TO_TICKS(1000));
}
}  // namespace toit

extern "C" void vApplicationStackOverflowHook(TaskHandle_t, char* name) {
  panic("FreeRTOS stack overflow: %s", name);
}

int main() {
  toit::initialize_rp2350_watchdog();
  toit::initialize_rp2350_time();
  const uint8_t read_id[] = {0x9f, 0, 0, 0};
  uint32_t interrupts = save_and_disable_interrupts();
  flash_do_cmd(read_id, toit::flash_id, sizeof(read_id));
  restore_interrupts(interrupts);
  stdio_init_all();
  if (xTaskCreate(toit::run_vm, "toit", 4096, nullptr, 1, nullptr) != pdPASS) {
    panic("Unable to start Toit task");
  }
  vTaskStartScheduler();
  panic("FreeRTOS scheduler returned");
}
