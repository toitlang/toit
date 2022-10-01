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

#ifdef TOIT_FREERTOS

namespace toit {

// The RTC memory holds state that is preserved across reboots.
class RtcMemory {
 public:
  // Keep in sync with `RTC_MEMORY_SIZE` in `lib/esp32.toit`.
  static const int RTC_USER_DATA_SIZE = 4096;

  // Run at program startup (after FreeRTOS is initialized).
  static void set_up();
  // Update before going into deep sleep.
  static void before_deep_sleep();

  static void checkpoint();

  // Time is reported in microseconds.
  static uint64 total_deep_sleep_time();
  static uint64 total_run_time();

  // Boot counts.
  static uint32 boot_count();
  static int boot_failures();
  static void register_successful_boot();

  // Out of memory counts.
  static int out_of_memory_count();
  static void register_out_of_memory();
  static void register_successful_out_of_memory_report(int count);

  // WiFi data.
  static uint8 wifi_channel();
  static void set_wifi_channel(uint8 channel);

  // OTA resume data.
  static const uint8* ota_uuid();
  static uint32 ota_patch_position();
  static uint32 ota_image_position();
  static uint32 ota_image_size();
  static void set_ota_checkpoint(const uint8* uuid, uint32 patch_position, uint32 image_position, uint32 image_size);

  static void set_last_time(int64 accuracy, int64 time_s, int32 time_ns);
  static bool is_last_time_set();
  static int64 last_time_ns_accuracy();
  static int64 last_time_s();
  static int32 last_time_ns();

  static bool has_connection_tokens();
  static void set_connection_tokens(uint8 tokens);
  static void decrement_connection_tokens();

  static void set_session_id(uint32 session_id);
  static uint32 session_id();

  static uint8* user_data_address();
};

} // namespace toit

#endif  // TOIT_FREERTOS
