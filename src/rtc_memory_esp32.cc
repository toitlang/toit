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

#include "objects.h"
#include "os.h"
#include "embedded_data.h"
#include "top.h"
#include "utils.h"
#include "uuid.h"

#ifdef TOIT_ESP32

#include "rtc_memory_esp32.h"
#include "esp_attr.h"
#include "esp_system.h"

#ifdef CONFIG_IDF_TARGET_ESP32
  #include <esp32/rom/ets_sys.h>
  #include <esp32/rtc.h>
#elif CONFIG_IDF_TARGET_ESP32C3
  #include <esp32c3/rom/ets_sys.h>
  #include <esp32c3/rtc.h>
#elif CONFIG_IDF_TARGET_ESP32S3
  #include <esp32s3/rom/ets_sys.h>
  #include <esp32s3/rtc.h>
#elif CONFIG_IDF_TARGET_ESP32S2
  #include <esp32s2/rom/ets_sys.h>
  #include <esp32s2/rtc.h>
#elif CONFIG_IDF_TARGET_ESP32C6
  #include <esp32c6/rom/ets_sys.h>
  #include <esp32c6/rtc.h>
#else
  #error "Unsupported ESP32 target"
#endif

#ifndef CONFIG_IDF_TARGET_ESP32
extern "C" {
  esp_err_t esp_timer_impl_early_init(void);
}
#endif

struct RtcData {
  uint64 rtc_time_us_before_deep_sleep;
  uint64 rtc_time_us_accumulated_deep_sleep;
  uint64 system_time_us_before_deep_sleep;

  uint32 boot_count;
  uint32 out_of_memory_count;

  uint8 wifi_channel;
};

// Keep the RTC state in the noinit segment that isn't cleared on reboots.
static RTC_NOINIT_ATTR RtcData rtc;
static RTC_NOINIT_ATTR uint32 rtc_checksum;
static RTC_NOINIT_ATTR uint8 rtc_user_data[toit::RtcMemory::RTC_USER_DATA_SIZE];
static bool is_rtc_invalid_in_start_cpu0 = false;

extern "C" void start_cpu0_default(void) IRAM_ATTR __attribute__((noreturn));

extern int _rtc_bss_start;
extern int _rtc_bss_end;

static uint32 compute_rtc_checksum() {
  uint32 vm_checksum = toit::Utils::crc32(0x12345678, toit::EmbeddedData::uuid(), toit::UUID_SIZE);
  return toit::Utils::crc32(vm_checksum, reinterpret_cast<uint8*>(&rtc), sizeof(rtc));
}

static void update_rtc_checksum() {
  rtc_checksum = compute_rtc_checksum();
}

static bool is_rtc_valid() {
  return rtc_checksum == compute_rtc_checksum();
}

static void reset_rtc(const char* reason) {
  ets_printf("[toit] DEBUG: clearing RTC memory: %s\n", reason);
  // Clear the RTC .bss segment.
  memset(&_rtc_bss_start, 0, (&_rtc_bss_end - &_rtc_bss_start) * sizeof(_rtc_bss_start));
  // Our RTC state is kept in the noinit segment, which means that it isn't
  // automatically cleared on reset. Since it is invalid now, we clear it.
  memset(&rtc, 0, sizeof(rtc));
  memset(&rtc_user_data, 0, sizeof(rtc_user_data));
  // We only clear RTC on boot, so this must be exactly 1.
  rtc.boot_count = 1;
  update_rtc_checksum();

#ifndef CONFIG_IDF_TARGET_ESP32
  // Non-ESP32 targets use the SYSTIMER which needs a call to early init.
  // https://github.com/toitware/esp-idf/blob/67fa2950f6bed9cc8e2e89a8ffac1ed77f087214/components/esp_timer/Kconfig#L54
  esp_timer_impl_early_init();
#endif

  // Clear real-time clock.
#ifndef CONFIG_IDF_TARGET_ESP32S3
  struct timespec time = { 0, 0 };
  toit::OS::set_real_time(&time);
#endif
}

// Patch the primordial entrypoint of the image (before launching FreeRTOS).
extern "C" void IRAM_ATTR start_cpu0() {
  if (is_rtc_valid()) {
    uint64 elapsed = esp_rtc_get_time_us() - rtc.rtc_time_us_before_deep_sleep;
    rtc.rtc_time_us_accumulated_deep_sleep += elapsed;
    rtc.boot_count++;
    update_rtc_checksum();
  } else {
    // Delay the actual RTC memory reset until FreeRTOS has been launched.
    // We do this to avoid relying on more complex code (printing to UART)
    // this early in the boot process.
    is_rtc_invalid_in_start_cpu0 = true;
  }

  // Invoke the default entrypoint that launches FreeRTOS and the real application.
  start_cpu0_default();
}

namespace toit {

void RtcMemory::set_up() {
  ets_printf("[toit] INFO: starting <%s>\n", toit::vm_git_version());

  if (is_rtc_invalid_in_start_cpu0) {
    reset_rtc("invalid checksum");
    return;
  }

  switch (esp_reset_reason()) {
    case ESP_RST_SW:
    case ESP_RST_PANIC:
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_DEEPSLEEP:
      // Time drifted backwards while sleeping, clear RTC.
      if (rtc.system_time_us_before_deep_sleep > OS::get_system_time()) {
        reset_rtc("system time drifted backwards");
      }
      break;

    default:
      // We got a non-software triggered power-on event. Play it safe by clearing RTC.
      reset_rtc("powered on by hardware source");
      break;
  }
}

void RtcMemory::invalidate() {
  // Set the RTC checksum to an invalid value, so we get
  // the memory cleared on next boot.
  rtc_checksum = compute_rtc_checksum() + 1;
}

void RtcMemory::on_deep_sleep_start() {
  rtc.system_time_us_before_deep_sleep = OS::get_system_time();
  rtc.rtc_time_us_before_deep_sleep = esp_rtc_get_time_us();
  update_rtc_checksum();
}

void RtcMemory::on_out_of_memory() {
  rtc.out_of_memory_count++;
  update_rtc_checksum();
}

uint32 RtcMemory::boot_count() {
  return rtc.boot_count;
}

uint32 RtcMemory::out_of_memory_count() {
  return rtc.out_of_memory_count;
}

uint64 RtcMemory::accumulated_deep_sleep_time_us() {
  return rtc.rtc_time_us_accumulated_deep_sleep;
}

uint8 RtcMemory::wifi_channel() {
  return rtc.wifi_channel;
}

void RtcMemory::set_wifi_channel(uint8 channel) {
  rtc.wifi_channel = channel;
  update_rtc_checksum();
}

uint8* RtcMemory::user_data_address() {
  return rtc_user_data;
}

} // namespace toit

#endif  // TOIT_ESP32
