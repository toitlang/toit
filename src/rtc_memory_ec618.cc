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

#include "rtc_memory_ec618.h"
#include "embedded_data.h"
#include "os.h"
#include "utils.h"
#include "uuid.h"

extern "C" {
  #include "cmsis_os2.h"
  #include "slpman.h"
}

namespace toit {

struct RtcData {
  int64 wakeup_time;  // Accumulated ticks in ms across sleep cycles.

  uint32 boot_count;
  uint32 out_of_memory_count;
};

// Place RTC data in a noinit section that is not zeroed on warm boot.
// This section must be defined in the linker script in the ASMB (always-on SRAM) area.
static RtcData rtc __attribute__((__section__(".toit.rtc.noinit")));
static uint32 rtc_checksum __attribute__((__section__(".toit.rtc.noinit")));
static uint8 rtc_user_data[RtcMemory::RTC_USER_DATA_SIZE] __attribute__((__section__(".toit.rtc.noinit")));

static uint32 compute_rtc_checksum() {
  uint32 vm_checksum = Utils::crc32(0x12345678, EmbeddedData::uuid(), UUID_SIZE);
  return Utils::crc32(vm_checksum, reinterpret_cast<uint8*>(&rtc), sizeof(rtc));
}

static void update_rtc_checksum() {
  rtc_checksum = compute_rtc_checksum();
}

static bool is_rtc_valid() {
  return rtc_checksum == compute_rtc_checksum();
}

static void reset_rtc(const char* reason) {
  printf("[toit] DEBUG: clearing RTC memory: %s\n", reason);
  memset(&rtc, 0, sizeof(rtc));
  memset(&rtc_user_data, 0, sizeof(rtc_user_data));
  rtc.boot_count = 1;
  update_rtc_checksum();
}

void RtcMemory::set_up() {
  slpManSlpState_t last_state = slpManGetLastSlpState();

  switch (last_state) {
    case SLP_SLP2_STATE:
      // Warm boot from deep sleep (sleep2).
      if (is_rtc_valid()) {
        rtc.boot_count++;
        update_rtc_checksum();
      } else {
        reset_rtc("invalid checksum after deep sleep");
      }
      break;

    case SLP_ACTIVE_STATE:
    case SLP_HIB_STATE:
    default:
      // Cold boot or hibernation wake — clear everything.
      reset_rtc("cold boot or hibernation");
      break;
  }
}

void RtcMemory::invalidate() {
  rtc_checksum = compute_rtc_checksum() + 1;
}

void RtcMemory::on_deep_sleep_start() {
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

int64 RtcMemory::wakeup_time() {
  return rtc.wakeup_time;
}

void RtcMemory::adjust_wakeup_time_before_sleep(uint32 sleep_ms) {
  uint32_t current_ticks = osKernelGetTickCount();
  int64 current_ms = static_cast<int64>(current_ticks) * portTICK_PERIOD_MS;
  rtc.wakeup_time += current_ms + sleep_ms;
  update_rtc_checksum();
}

uint8* RtcMemory::user_data_address() {
  return rtc_user_data;
}

}  // namespace toit

#endif  // TOIT_EC618
