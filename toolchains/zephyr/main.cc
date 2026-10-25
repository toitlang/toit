// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "embedded_data.h"
#include "entropy_mixer.h"
#include "flash_registry.h"
#include "memory.h"
#include "messaging.h"
#include "os.h"
#include "program.h"
#include "primitive_zephyr.h"
#include "scheduler.h"
#include "vm.h"
#include <zephyr/kernel.h>
#include <zephyr/sys/reboot.h>

#ifdef TOIT_ZEPHYR_STARTUP_TEST
extern "C" int toit_zephyr_startup_test(void);
#endif

namespace toit {
extern void set_up_mbedtls_threading();
void run_vm() {
  printf("[toit] Zephyr VM starting\n");
  zephyr_capture_reset_reason();
  OS::set_up();
  FlashRegistry::set_up();
  ObjectMemory::set_up();
  set_up_mbedtls_threading();
  EntropyMixer::instance()->set_up();
#ifdef TOIT_ZEPHYR_STARTUP_TEST
  if (toit_zephyr_startup_test() != 0) FATAL("Zephyr startup qualification failed");
#endif
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
  if (result.reason == Scheduler::EXIT_ERROR) {
    // The system container forwards critical-container failures here. Release
    // every VM resource first, then bound the rate of repeated failing boots.
    // An armed application watchdog remains active during this delay.
    printf("[toit] restarting after VM error in 1000 ms\n");
    fflush(stdout);
    k_sleep(K_MSEC(1000));
    sys_reboot(SYS_REBOOT_COLD);
  }
  if (result.reason == Scheduler::EXIT_RESET) {
    printf("[toit] resetting chip\n");
    fflush(stdout);
    sys_reboot(SYS_REBOOT_COLD);
  }
  if (result.reason == Scheduler::EXIT_DEEP_SLEEP) {
    zephyr_enter_sleep(result.value);
  }
}
}  // namespace toit

int main() { toit::run_vm(); return 0; }
