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

#include "watchdog_ec618.h"

#include "resources/pad_table_ec618.h"

extern "C" {
  #include "clock.h"
  #include "FreeRTOS.h"
  #include "task.h"
  #include "cmsis_os2.h"
  #include "wdt.h"
}

namespace toit {

[[noreturn]] void ec618_system_reset();

// EC618 watchdog — a software watchdog with a hardware busy-lockup backstop.
//
// Neither hardware watchdog on this chip can catch an *idle* application
// wedge (both HW-verified, 2026-06-09/10):
//
//  - The WDT module counts only CPU-ACTIVE time: its 32 kHz functional clock
//    (CLK_32K_GATED) is gated whenever the chip enters tickless idle / WFI,
//    and the clock mux has no always-on source. Verified with the vendor-
//    exact luat_wdt_setup sequence: armed at 10 s, feeds stopped, 72 s of
//    idle — no reset.
//
//  - The always-on (AON) watchdog belongs to the platform, not to us. The
//    boot ROM arms it (~27 s) and the CP core then auto-feeds it every couple
//    of seconds (its target register 0x4D020318 slides forward, target-now
//    pinned at ~20 s, with every AP-side feeder provably silent). It guards
//    whole-chip/CP liveness. It only ever fires when no healthy CP runs —
//    the early-bring-up ~27 s reboot loops (CONFIG_TOIT_EC618_VM_WATCHDOG=0
//    stops it at boot for CP-less debugging) — and it must be stopped before
//    hibernate, where the CP stops feeding (toit_ec618.cc does).
//
// So the real timeout is enforced in software: a dedicated FreeRTOS task
// (independent of the Toit scheduler thread, so it survives a wedged VM;
// FreeRTOS timed waits wake the chip from tickless idle, so it works through
// light sleep) checks a feed deadline and resets the chip when it passes.
// The task also kicks the WDT module: if the CPU is busy-locked hard enough
// to starve the task (IRQ-off spin, interrupt storm), the WDT accumulates
// active time with nobody kicking it and fires the hardware reset instead.
static volatile bool wd_armed = false;
static volatile uint32_t wd_timeout_ms = 0;
static volatile uint32_t wd_deadline = 0;  // 1 kHz ticks; compared by signed difference.
static bool wd_task_created = false;

// Cap on the task's sleep. Bounds the WDT-kick interval: legitimate heavy
// compute accrues at most this much active time between kicks, far below the
// backstop period, so the WDT only fires when the task is truly starved.
static const uint32_t WD_MAX_SLEEP_MS = 5000;
// The WDT backstop period in seconds of ACTIVE time (32 kHz / div(10) with a
// 32768 reload; interrupt+reset mode resets on the second expiry, so a
// starved-task busy lockup resets within 10-20 s of active time).
static const int WD_BACKSTOP_S = 10;

#if CONFIG_TOIT_EC618_WATCHDOG_FATAL_PAD >= 0
static_assert(CONFIG_TOIT_EC618_WATCHDOG_FATAL_PAD > 0 &&
              CONFIG_TOIT_EC618_WATCHDOG_FATAL_PAD <= kMaxPadIndex,
              "watchdog fatal marker must be a physical EC618 PAD");
#endif

static void watchdog_task(void* arg) {
  (void)arg;
  while (true) {
    uint32_t sleep_ms = WD_MAX_SLEEP_MS;
    if (wd_armed) {
      WDT_kick();
      int32_t remain = static_cast<int32_t>(wd_deadline - osKernelGetTickCount());
      if (remain <= 0) {
#if CONFIG_TOIT_EC618_WATCHDOG_FATAL_PAD >= 0
        // Optional scope trigger goes HIGH before anything else in this path.
        // A reset without it came from elsewhere (the busy backstop, platform
        // watchdog, power, or another fatal path).
        pad_emergency_high(CONFIG_TOIT_EC618_WATCHDOG_FATAL_PAD);
#endif
        printf("[toit] FATAL: watchdog timeout (%u ms without feed) — resetting\n",
               static_cast<unsigned>(wd_timeout_ms));
        ec618_system_reset();
      }
      if (static_cast<uint32_t>(remain) < sleep_ms) {
        sleep_ms = static_cast<uint32_t>(remain);
      }
    }
    osDelay(sleep_ms);
  }
}

bool ec618_watchdog_init(int seconds) {
  wd_timeout_ms = static_cast<uint32_t>(seconds) * 1000;
  wd_deadline = osKernelGetTickCount() + wd_timeout_ms;
  if (!wd_task_created) {
    // Arm the busy-lockup backstop (see above) before the task that kicks it.
    GPR_setClockSrc(FCLK_WDG, FCLK_WDG_SEL_32K);
    GPR_setClockDiv(FCLK_WDG, WD_BACKSTOP_S);
    WdtConfig_t config;
    config.mode = WDT_INTERRUPT_RESET_MODE;
    config.timeoutValue = 32768U;
    WDT_init(&config);
    WDT_start();
    // Priority above the Toit task (20), so a spinning Toit process cannot
    // starve the watchdog check. Stack in words; 1024 = 4 KB covers printf.
    if (xTaskCreate(watchdog_task, "toit_wd", 1024, null, 30, null) != pdPASS) {
      WDT_stop();
      WDT_deInit();
      return false;
    }
    wd_task_created = true;
  }
  wd_armed = true;
  return true;
}

void ec618_watchdog_feed() {
  if (wd_armed) wd_deadline = osKernelGetTickCount() + wd_timeout_ms;
}

void ec618_watchdog_deinit() {
  wd_armed = false;
  // The task stays parked (one wake per 5 s); the backstop WDT keeps being
  // kicked by it, which is harmless and keeps the arm/disarm logic race-free.
}

// Called from the deep-sleep path after the VM has exited. An armed watchdog's
// deadline keeps counting while the chip waits to enter hibernate, and nobody
// feeds it any more. Don't disarm it: a blocked sleep entry would then hang the
// device forever. A successful hibernate kills the task with the rest of the
// AP; a blocked entry self-recovers after diagnostics have time to print.
extern "C" void toit_watchdog_presleep() {
  if (!wd_armed) return;
  wd_timeout_ms = 120 * 1000;
  wd_deadline = osKernelGetTickCount() + wd_timeout_ms;
}

}  // namespace toit

#endif  // TOIT_EC618
