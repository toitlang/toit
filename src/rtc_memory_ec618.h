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

#pragma once

#include "top.h"

#ifdef TOIT_EC618

namespace toit {

// RTC memory holds state that is preserved across deep-sleep reboots.
// On EC618, this uses a noinit section in the always-on SRAM (ASMB area).
class RtcMemory {
 public:
  // Run at program startup (after FreeRTOS is initialized).
  static void set_up();

  // Force clearing of the RTC memory on next boot.
  static void invalidate();

  // Event registration.
  static void on_out_of_memory();
  static void on_deep_sleep_start();

  // Event counters.
  static uint32 boot_count();
  static uint32 out_of_memory_count();

  // Wakeup time: accumulated ticks across sleep cycles (in ms).
  static int64 wakeup_time();

  // Called before entering deep sleep: records current tick count + sleep
  // duration so system time is approximately correct after waking.
  static void adjust_wakeup_time_before_sleep(uint32 sleep_ms);

  // User data.
  static uint8* user_data_address();

  // Keep in sync with `RTC_MEMORY_SIZE` in lib/esp32.toit (and EC618 equivalent).
  static const int RTC_USER_DATA_SIZE = 2048;
};

}  // namespace toit

#endif  // TOIT_EC618
