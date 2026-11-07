// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "pico/stdlib.h"
#include "hardware/watchdog.h"
#include "hardware/structs/watchdog.h"
#include "FreeRTOS.h"
#include "task.h"
#include "embedded_data.h"
#include "entropy_mixer.h"
#include "flash_registry.h"
#include "memory.h"
#include "messaging.h"
#include "os.h"
#include "program.h"
#include "scheduler.h"
#include "vm.h"
#include "update.h"
#include "tusb.h"

// USB control requests must not consume application stdin or reset in the
// middle of a flash operation. The boot process polls this flag and exits;
// normal VM teardown joins outstanding native workers before rebooting.
static volatile bool recovery_requested = false;

extern "C" void tud_cdc_line_coding_cb(uint8_t interface, const cdc_line_coding_t* coding) {
  if (interface == 0 && coding->bit_rate == 1200) recovery_requested = true;
}

extern "C" bool toit_rp2040_recovery_requested() {
  return recovery_requested;
}

extern "C" void __malloc_lock(struct _reent*) { vTaskSuspendAll(); }
extern "C" void __malloc_unlock(struct _reent*) { xTaskResumeAll(); }

#ifdef TOIT_RP2350_TEST_FAULT
extern void schedule_rp2350_failure_test();
#endif

namespace toit {
extern void set_up_mbedtls_threading();

static void run_vm(void*) {
  vTaskDelay(pdMS_TO_TICKS(1500));
  printf("[toit] RP2040 VM starting\n");
#ifdef TOIT_RP2350_TEST_FAULT
  schedule_rp2350_failure_test();
#endif
  OS::set_up();
  FlashRegistry::set_up();
  ObjectMemory::set_up();
  set_up_mbedtls_threading();
  EntropyMixer::instance()->set_up();
  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  if (!extension || extension->images() < 1) FATAL("missing boot image");
  auto program = const_cast<Program*>(extension->image(0).program);
  if (!program->is_valid_embedded()) FATAL("invalid boot image");
  Scheduler::ExitState result;
  {
    VM vm;
    vm.load_platform_event_sources();
    create_and_start_external_message_handlers(&vm);
    result = vm.scheduler()->run_boot_program(program, vm.scheduler()->next_group_id());
    printf("[toit] VM exited: reason=%d value=%lld\n", result.reason,
        static_cast<long long>(result.value));
  }
  // Teardown has stopped resource/event tasks before restarting. A normal
  // reset boots the installed application; failures and console update requests
  // enter recovery. watchdog_reboot clears the SDK's watchdog-expiration marker.
  watchdog_hw->scratch[0] = result.reason == Scheduler::EXIT_RESET ? 0 : UPDATE_REQUEST;
  watchdog_reboot(0, 0, 100);
  for (;;) tight_loop_contents();
}
}  // namespace toit

extern "C" void vApplicationStackOverflowHook(TaskHandle_t, char* name) {
  panic("FreeRTOS stack overflow: %s", name);
}

int main() {
  watchdog_enable(8000, false);
  stdio_init_all();
  if (xTaskCreate(toit::run_vm, "toit", 4096, nullptr, 1, nullptr) != pdPASS) {
    panic("Unable to start Toit task");
  }
  vTaskStartScheduler();
  panic("FreeRTOS scheduler returned");
}
