// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

// Linked only when TOIT_RP2350_TEST_FAULT is explicitly enabled. No test
// command or native fault-injection primitive is exposed by normal firmware.
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "pico/stdlib.h"
#include "pico/bootrom.h"
#include "FreeRTOS.h"
#include "task.h"
#include "top.h"

extern "C" void vApplicationStackOverflowHook(TaskHandle_t task, char* name);

static void __attribute__((noreturn, noinline)) __not_in_flash_func(inject_xip_failure)() {
  save_and_disable_interrupts();
  auto exit_xip = reinterpret_cast<rom_flash_exit_xip_fn>(
      rom_func_lookup_inline(ROM_FUNC_FLASH_EXIT_XIP));
  exit_xip();
  __asm volatile("udf #0");
  for (;;) __asm volatile("wfi");
}

static void inject_failure(void*) {
  vTaskDelay(pdMS_TO_TICKS(3000));
  printf("[test] injecting native %s\n", TOIT_RP2350_TEST_FAULT);
  vTaskDelay(pdMS_TO_TICKS(20));
  if (strcmp(TOIT_RP2350_TEST_FAULT, "abort") == 0) abort();
  if (strcmp(TOIT_RP2350_TEST_FAULT, "exit") == 0) _exit(1);
  if (strcmp(TOIT_RP2350_TEST_FAULT, "fatal") == 0) {
    FATAL("deliberate native fatal");
  }
  if (strcmp(TOIT_RP2350_TEST_FAULT, "panic") == 0) {
    // Prove that panic recovery doesn't require the RTOS tick or USB IRQ.
    save_and_disable_interrupts();
    panic("deliberate panic with interrupts disabled");
  }
  if (strcmp(TOIT_RP2350_TEST_FAULT, "hardfault") == 0) {
    save_and_disable_interrupts();
    __asm volatile("udf #0");
  }
  if (strcmp(TOIT_RP2350_TEST_FAULT, "xip-fault") == 0) inject_xip_failure();
  if (strcmp(TOIT_RP2350_TEST_FAULT, "watchdog-hang") == 0) {
    // No panic, ROM reboot, RTOS tick, or feeder can rescue this loop. Only
    // the application watchdog armed before entering it may reset the chip.
    save_and_disable_interrupts();
    for (;;) __asm volatile("nop");
  }
  if (strcmp(TOIT_RP2350_TEST_FAULT, "stack-overflow") == 0) {
    char name[] = "fault-test";
    vApplicationStackOverflowHook(nullptr, name);
  }
  panic("invalid native failure test");
}

void schedule_rp2350_failure_test() {
  // Called only on a trial boot. An auto-validated test image will therefore
  // restart normally once, without injecting the fault again on later boots.
  if (xTaskCreate(inject_failure, "fault-test", 1024, nullptr, 1, nullptr) != pdPASS) {
    panic("unable to start failure test");
  }
}
