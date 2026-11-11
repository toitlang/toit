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

// The EC618 base, as far as the QEMU harness needs it: the hooks of the
// prebuilt FreeRTOS kernel (libfreertos.a: trace, clock and sleep hooks;
// its cmsis_os2.o has the memory of the static tasks) and the TRNG. Without the PLAT headers, whose
// declarations of the same functions differ in details that do not matter
// here (the AAPCS passes the same registers).

#include <stdint.h>
#include <stdio.h>
#include <string.h>

void harness_puts(const char* s);
__attribute__((noreturn)) void harness_exit(int code);

void vApplicationStackOverflowHook(void* task, char* name) {
  (void)task;
  harness_puts("\n[harness] stack overflow in task ");
  harness_puts(name);
  harness_puts("\n");
  harness_exit(71);
}

void excepEcAssert(const char* function, uint32_t line, uint32_t v1, uint32_t v2, uint32_t v3) {
  (void)v1; (void)v2; (void)v3;
  printf("\n[harness] EC assert in %s:%u\n", function, (unsigned)line);
  fflush(stdout);
  harness_exit(72);
}

void ec_assert_regs(void) {}

// Hooks without an effect here.
void ecTraceTaskCreate(void* task) { (void)task; }
void ecTraceTaskSwitchIn(void) {}
void ecTraceTaskSwitchOut(void) {}
void vTracePrintSchedule(uint32_t parameter) { (void)parameter; }
void vTraceScheduleRecord(uint32_t parameter) { (void)parameter; }
void setOSState(uint8_t state) { (void)state; }
void GPR_switchSystickClk(uint32_t clock) { (void)clock; }
void WDT_kick(void) {}
void am_power_time_update(void) {}
void* UsartPrintHandle = 0;
void swLogPrintf(uint32_t id, uint8_t level, ...) { (void)id; (void)level; }

// Tickless idle: sleep until the next interrupt (the SysTick keeps running).
void xpmuEnterTickless(uint32_t expected_idle_ticks) {
  (void)expected_idle_ticks;
  __asm__ volatile("wfi");
}

// The TRNG (24 bytes per call): a fixed xorshift sequence, so that runs are
// reproducible.
int rngGenRandom(uint8_t* output) {
  static uint32_t state = 0x2545f491;
  for (int i = 0; i < 24; i += 4) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    memcpy(output + i, &state, 4);
  }
  return 0;
}
