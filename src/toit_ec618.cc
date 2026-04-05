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
  #include "slpman.h"
  #include "plat_config.h"

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

static void start() {
  // Run C++ static initializers (the linker script must capture .init_array).
  run_static_initializers();

  // On fault/assert: print exception info then reset (instead of looping).
  BSP_SetPlatConfigItemValue(PLAT_CONFIG_ITEM_FAULT_ACTION, 1);

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
    // The OTA commit (verifying SHA-256 and copying from FOTA to active
    // image) is a complex operation that will be implemented when the
    // firmware tooling is ready. For now, just log and reboot.
    // TODO: Implement FOTA → active image copy with SHA-256 verification.
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
