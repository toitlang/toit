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
#include "sha256.h"
#include "top.h"
#include "utils.h"
#include "uuid.h"

#ifdef TOIT_FREERTOS

#include "rtc_memory_esp32.h"
#include "esp_attr.h"
#include <soc/rtc.h>

#ifdef CONFIG_IDF_TARGET_ESP32C3
  #include <esp32c3/rom/ets_sys.h>
#else
  #include <esp32/rom/ets_sys.h>
#endif

#include "esp_system.h"

extern "C" {
#ifdef CONFIG_IDF_TARGET_ESP32C3
  #include <esp32c3/clk.h>
#else
  #include <esp32/clk.h>
#endif
}

struct RTCData {
  uint64 total_deep_sleep_time;
  uint64 deep_sleep_time_stamp;

  uint32 boot_count;
  uint32 boot_count_last_successful;
  word out_of_memory_count;

  uint8 wifi_channel;

  uint8 ota_uuid[toit::UUID_SIZE];
  uint32 ota_patch_position;
  uint32 ota_image_position;
  uint32 ota_image_size;

  int64 time_ns_accuracy;
  int64 last_time_s;
  int32 last_time_ns;
  bool last_time_set;

  uint8 connection_tokens;

  uint64 system_time_checkpoint;
  uint32 session_id;
};

// Keep the RTC state in the noinit segment that isn't cleared on reboots.
static RTC_NOINIT_ATTR RTCData rtc;
static RTC_NOINIT_ATTR uint32 rtc_checksum;
static RTC_NOINIT_ATTR uint8 rtc_user_data[toit::RtcMemory::RTC_USER_DATA_SIZE];
static bool reset_after_boot = false;

extern "C" void start_cpu0_default(void) IRAM_ATTR __attribute__((noreturn));

extern int _rtc_bss_start;
extern int _rtc_bss_end;

inline uint64_t calibrated_rtc_time() {
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
  uint32 vm_checksum = crc32(0x12345678, toit::OS::image_uuid(), toit::UUID_SIZE);
  return crc32(vm_checksum, reinterpret_cast<uint8*>(&rtc), sizeof(rtc));
}

static void update_rtc_checksum() {
  rtc_checksum = compute_rtc_checksum();
}

static bool is_rtc_valid() {
  return rtc_checksum == compute_rtc_checksum();
}

static void reset_rtc(const char* reason) {
  ets_printf("clearing RTC memory: %s\n", reason);
  // Clear the RTC .bss segment.
  memset(&_rtc_bss_start, 0, (&_rtc_bss_end - &_rtc_bss_start) * sizeof(_rtc_bss_start));
  // Our RTC state is kept in the noinit segment, which means that it isn't
  // automatically cleared on reset. Since it is invalid now, we clear it.
  memset(&rtc, 0, sizeof(rtc));
  // We only clear RTC on boot, so this must be exactly 1.
  rtc.boot_count = 1;
  // Clear real-time clock.
  struct timespec time = { 0, 0 };
  toit::OS::set_real_time(&time);
  // Checksum will be updated after.
  reset_after_boot = true;
}

// Patch the primordial entrypoint of the image (before launching FreeRTOS).
extern "C" void IRAM_ATTR start_cpu0() {
  if (!is_rtc_valid()) {
    reset_rtc("RTC memory is in inconsistent state");
  } else {
    rtc.boot_count++;
    rtc.total_deep_sleep_time += calibrated_rtc_time() - rtc.deep_sleep_time_stamp;
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
      if (rtc.system_time_checkpoint > OS::get_system_time()) {
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

void RtcMemory::before_deep_sleep() {
  rtc.system_time_checkpoint = OS::get_system_time();
  rtc.deep_sleep_time_stamp = calibrated_rtc_time();
  update_rtc_checksum();
}

void RtcMemory::checkpoint() {
  rtc.system_time_checkpoint = OS::get_system_time();
  update_rtc_checksum();
}

uint64 RtcMemory::total_deep_sleep_time() {
  return rtc.total_deep_sleep_time;
}

uint64 RtcMemory::total_run_time() {
  return calibrated_rtc_time();
}

uint32 RtcMemory::boot_count() {
  return rtc.boot_count;
}

int RtcMemory::boot_failures() {
  uint32 difference = rtc.boot_count - rtc.boot_count_last_successful;
  // If the difference is zero, we've just marked the boot as
  // successful, so there have been no failures. Otherwise, we
  // subtract one to account for the most recent boot and cap
  // the result to avoid overflowing smi limits, etc.
  return (difference == 0) ? 0 : Utils::min(0xffffU, difference - 1);
}

void RtcMemory::register_successful_boot() {
  rtc.boot_count_last_successful = rtc.boot_count;
  update_rtc_checksum();
}

int RtcMemory::out_of_memory_count() {
  return Utils::min(Smi::MAX_SMI_VALUE, rtc.out_of_memory_count);
}

void RtcMemory::register_out_of_memory() {
  int updated = rtc.out_of_memory_count + 1;
  // Check for wraparound.
  if (updated > 0) {
    rtc.out_of_memory_count = updated;
    update_rtc_checksum();
  }
}

void RtcMemory::register_successful_out_of_memory_report(int count) {
  if (count > 0 && count <= rtc.out_of_memory_count) {
    rtc.out_of_memory_count -= count;
    update_rtc_checksum();
  }
}

uint8 RtcMemory::wifi_channel() {
  return rtc.wifi_channel;
}

void RtcMemory::set_wifi_channel(uint8 channel) {
  rtc.wifi_channel = channel;
  update_rtc_checksum();
}

const uint8* RtcMemory::ota_uuid() {
  return rtc.ota_uuid;
}

uint32 RtcMemory::ota_patch_position() {
  return rtc.ota_patch_position;
}

uint32 RtcMemory::ota_image_position() {
  return rtc.ota_image_position;
}

uint32 RtcMemory::ota_image_size() {
  return rtc.ota_image_size;
}

void RtcMemory::set_ota_checkpoint(const uint8* uuid, uint32 patch_position, uint32 image_position, uint32 image_size) {
  memcpy(rtc.ota_uuid, uuid, UUID_SIZE);
  rtc.ota_patch_position = patch_position;
  rtc.ota_image_position = image_position;
  rtc.ota_image_size = image_size;
  update_rtc_checksum();
}

void RtcMemory::set_last_time(int64 accuracy, int64 time_s, int32 time_ns) {
  rtc.time_ns_accuracy = accuracy;
  rtc.last_time_s = time_s;
  rtc.last_time_ns = time_ns;
  rtc.last_time_set = true;
  update_rtc_checksum();
}

bool RtcMemory::is_last_time_set() {
  return rtc.last_time_set;
}

int64 RtcMemory::last_time_ns_accuracy() {
  return rtc.time_ns_accuracy;
}

int64 RtcMemory::last_time_s() {
  return rtc.last_time_s;
}

int32 RtcMemory::last_time_ns() {
  return rtc.last_time_ns;
}

bool RtcMemory::has_connection_tokens() {
  return rtc.connection_tokens > 0;
}

void RtcMemory::set_connection_tokens(uint8 tokens) {
  rtc.connection_tokens = tokens;
  update_rtc_checksum();
}

void RtcMemory::decrement_connection_tokens() {
  if (rtc.connection_tokens > 0) {
    rtc.connection_tokens--;
    update_rtc_checksum();
  }
}

void RtcMemory::set_session_id(uint32 session_id) {
  rtc.session_id = session_id;
  update_rtc_checksum();
}

uint32 RtcMemory::session_id() {
  return rtc.session_id;
}

void RtcMemory::set_user_data(uint8* data, int from, int length) {
  // memcpy doesn't work here.
  for (int i = 0; i < length; i++) {
    rtc_user_data[from + i] = data[i];
  }
}

void RtcMemory::user_data(uint8* data, int from, int length) {
  // memcpy doesn't work here.
  for (int i = 0; i < length; i++) {
    data[i] = rtc_user_data[from + i];
  }
}


} // namespace toit

#endif  // TOIT_FREERTOS
