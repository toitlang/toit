// Copyright (C) 2019 Toitware ApS.
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

#ifdef TOIT_ESP32

namespace toit {

// The RTC memory holds state that is preserved across reboots.
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

  // Time keeping.
  static uint64 accumulated_deep_sleep_time_us();

  // Deprecated: WiFi data.
  static uint8 wifi_channel();
  static void set_wifi_channel(uint8 channel);

  // Deprecated: User data.
  static uint8* user_data_address();

  // Keep in sync with `RTC_MEMORY_SIZE` in `lib/esp32.toit`.
  static const int RTC_USER_DATA_SIZE = 4096;
};

} // namespace toit

#endif  // TOIT_ESP32
