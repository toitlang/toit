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

#ifdef TOIT_FREERTOS

#include "rtc_memory_esp32.h"
#include "esp_attr.h"
#include <soc/rtc.h>

#ifdef CONFIG_IDF_TARGET_ESP32C3
  #include <esp32c3/rom/ets_sys.h>
#elif CONFIG_IDF_TARGET_ESP32S3
  #include <esp32s3/rom/ets_sys.h>
#elif CONFIG_IDF_TARGET_ESP32S2
  #include <esp32s2/rom/ets_sys.h>
#else
  #include <esp32/rom/ets_sys.h>
#endif

#include "esp_system.h"

extern "C" {
#ifdef CONFIG_IDF_TARGET_ESP32C3
  #include <esp32c3/clk.h>
#elif CONFIG_IDF_TARGET_ESP32S3
  #include <esp32s3/clk.h>
#else
  #include <esp32/clk.h>
#endif
}

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
static bool reset_after_boot = false;

extern "C" void start_cpu0_default(void) IRAM_ATTR __attribute__((noreturn));

extern int _rtc_bss_start;
extern int _rtc_bss_end;

static inline uint64 rtc_time_us_calibrated() {
  return rtc_time_slowclk_to_us(rtc_time_get(), esp_clk_slowclk_cal_get());
}

// Karl Malbrain's compact CRC-32. See "A compact CCITT crc16 and crc32 C implementation that balances processor
// cache usage against speed": http://www.geocities.com/malbrain/.
static uint32 crc32(uint32 crc, const uint8* ptr, size_t length) {
  static const uint32 s_crc32[16] = {
      0x00000000, 0x1db71064, 0x3b6e20c8, 0x26d930ac, 0x76dc4190, 0x6b6b51f4, 0x4db26158, 0x5005713c,
      0xedb88320, 0xf00f9344, 0xd6d6a3e8, 0xcb61b38c, 0x9b64c2b0, 0x86d3d2d4, 0xa00ae278, 0xbdbdf21c
  };
  uint32 crcu32 = crc;
  crcu32 = ~crcu32;
  while (length--) {
    uint8 b = *ptr++;
    crcu32 = (crcu32 >> 4) ^ s_crc32[(crcu32 & 0xF) ^ (b & 0xF)];
    crcu32 = (crcu32 >> 4) ^ s_crc32[(crcu32 & 0xF) ^ (b >> 4)];
  }
  return ~crcu32;
}

static uint32 compute_rtc_checksum() {
  uint32 vm_checksum = crc32(0x12345678, toit::EmbeddedData::uuid(), toit::UUID_SIZE);
  return crc32(vm_checksum, reinterpret_cast<uint8*>(&rtc), sizeof(rtc));
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
  // We only clear RTC on boot, so this must be exactly 1.
  rtc.boot_count = 1;

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
  // Checksum will be updated after.
  reset_after_boot = true;
}

// Patch the primordial entrypoint of the image (before launching FreeRTOS).
extern "C" void IRAM_ATTR start_cpu0() {
  ets_printf("[toit] INFO: starting <%s>\n", toit::vm_git_version());
  if (!is_rtc_valid()) {
    reset_rtc("invalid checksum");
  } else {
    rtc.boot_count++;
    uint64 elapsed = rtc_time_us_calibrated() - rtc.rtc_time_us_before_deep_sleep;
    rtc.rtc_time_us_accumulated_deep_sleep += elapsed;
  }

  // We always increment the boot count, so we always need to recalculate the
  // checksum.
  update_rtc_checksum();

  // Invoke the default entrypoint that launches FreeRTOS and the real application.
  start_cpu0_default();
}

namespace toit {

void RtcMemory::set_up() {
  // If the RTC memory was already reset, skip this step.
  if (reset_after_boot) return;

  switch (esp_reset_reason()) {
    case ESP_RST_SW:
    case ESP_RST_PANIC:
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_DEEPSLEEP:
      // Time drifted backwards while sleeping, clear RTC.
      if (rtc.system_time_us_before_deep_sleep > OS::get_system_time()) {
        reset_rtc("system time drifted backwards");
        update_rtc_checksum();
      }
      break;

    default:
      // We got a non-software triggered power-on event. Play it save by clearing RTC.
      reset_rtc("powered on by hardware source");
      update_rtc_checksum();
      break;
  }
}

void RtcMemory::on_deep_sleep_start() {
  rtc.system_time_us_before_deep_sleep = OS::get_system_time();
  rtc.rtc_time_us_before_deep_sleep = rtc_time_us_calibrated();
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

uint64 RtcMemory::accumulated_run_time_us() {
  return rtc_time_us_calibrated();
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

#endif  // TOIT_FREERTOS
