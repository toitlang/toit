// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "pico/bootrom.h"
#include "pico/platform.h"
#include "hardware/sync.h"
#include "boot/picoboot_constants.h"
#include "panic_rp2350.h"

// Failure recovery must not allocate, acquire a scheduler lock, or depend on
// USB progress. A normal ROM reboot rejects an unconfirmed trial and restarts
// confirmed firmware. In particular, don't select the failing slot again.
static void __not_in_flash_func(arm_failure_reboot)(uint32_t delay_ms) {
  // Use the forced-inline lookup directly. The SDK's ordinary inline
  // rom_reboot wrapper can be outlined into flash by the compiler.
  auto reboot = reinterpret_cast<rom_reboot_fn>(rom_func_lookup_inline(ROM_FUNC_REBOOT));
  reboot(REBOOT2_FLAG_REBOOT_TYPE_NORMAL, delay_ms, BOOT_PARTITION_NONE, 0);
}

static void __attribute__((noreturn)) __not_in_flash_func(wait_for_failure_reboot)() {
  for (;;) __asm volatile("wfi");
}

extern "C" void __attribute__((noreturn)) _exit(int status) {
  (void) status;
  save_and_disable_interrupts();
  arm_failure_reboot(10);
  wait_for_failure_reboot();
}

extern "C" void __attribute__((noreturn))
toit_rp2350_vpanic(const char* file, int line, const char* format, va_list arguments) {
  static bool reporting = false;
  save_and_disable_interrupts();
  if (reporting) _exit(1);
  reporting = true;
  // Arm before printing: panic can originate from an ISR, an allocator, or a
  // task already holding a stdio lock. Even blocked diagnostics must reboot.
  // Keep interrupts disabled: other tasks must not resume after a fatal error
  // or cancel this watchdog by confirming a trial concurrently.
  arm_failure_reboot(1000);
  puts("[toit] native panic; rebooting");
  if (file != nullptr) printf("%s:%d: ", file, line);
  if (format != nullptr) {
    vprintf(format, arguments);
    puts("");
  }
  wait_for_failure_reboot();
}

extern "C" void __attribute__((noreturn, format(printf, 1, 2)))
toit_rp2350_panic(const char* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  toit_rp2350_vpanic(nullptr, 0, format, arguments);
}

extern "C" void __attribute__((noreturn)) abort() {
  toit_rp2350_panic("abort");
}

extern "C" void __attribute__((noreturn))
__assert_func(const char* file, int line, const char* function, const char* expression) {
  toit_rp2350_panic("assertion %s: %s:%d (%s)", expression, file, line,
      function == nullptr ? "" : function);
}

// A fault may have exhausted the task stack or the interrupt stack. Switch to
// a dedicated, aligned stack before entering C, including clearing MSPLIM.
// Both the handler and reboot helper execute from SRAM so a fault in XIP code
// does not require fetching more application instructions from flash.
extern "C" {
alignas(8) uint32_t toit_rp2350_fault_stack[256];

void __attribute__((noreturn)) __not_in_flash_func(toit_rp2350_fault_reboot)() {
  arm_failure_reboot(10);
  wait_for_failure_reboot();
}

void __attribute__((naked, noreturn)) __not_in_flash_func(isr_hardfault)() {
  __asm volatile(
      "cpsid i\n"
      "movs r0, #0\n"
      "msr msplim, r0\n"
      "ldr r0, =toit_rp2350_fault_stack + 1024\n"
      "msr msp, r0\n"
      "b toit_rp2350_fault_reboot\n");
}

void isr_nmi() __attribute__((noreturn, alias("isr_hardfault")));
void isr_memmanage() __attribute__((noreturn, alias("isr_hardfault")));
void isr_busfault() __attribute__((noreturn, alias("isr_hardfault")));
void isr_usagefault() __attribute__((noreturn, alias("isr_hardfault")));
void isr_securefault() __attribute__((noreturn, alias("isr_hardfault")));
}
