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
  #include "slpman.h"
}

extern "C" {
  #include "cmsis_os2.h"
  #include "slpman.h"
  #include "flash_rt.h"
  #include "mem_map.h"
}

namespace toit {

struct RtcData {
  int64 wakeup_time;  // Accumulated ticks in ms across sleep cycles.

  uint32 boot_count;
  uint32 out_of_memory_count;
};

// Place RTC data in a noinit section that is not zeroed on warm boot.
// This section must be defined in the linker script in the ASMB (always-on SRAM) area.
// Explicit initializer + `used` attribute prevent the compiler from
// emitting these as COMMON/BSS symbols (which would bypass the section
// attribute and get zeroed by the startup BSS clear loop). The section
// is NOLOAD in the linker script, so the initializer does not consume
// flash — it just tells the compiler "this is .data-like", which makes
// it honor the section attribute.
static RtcData rtc __attribute__((used, section(".toit.rtc.noinit"))) = {};
static uint32 rtc_checksum __attribute__((used, section(".toit.rtc.noinit"))) = 0;
static uint8 rtc_user_data[RtcMemory::RTC_USER_DATA_SIZE]
    __attribute__((used, section(".toit.rtc.noinit"))) = {};

// Flash-backed persistence: a dedicated 4KB sector at the start of the
// FS region (0x384000), which is unused in the Toit port. The noinit
// section does not survive HIBERNATE, so we save to flash before sleep
// and restore from flash on boot.
static const uint32_t RTC_FLASH_OFFSET = 0x00384000;
static const uint32_t RTC_FLASH_SIZE = 0x1000;

// Total size of the data we save/restore to/from flash.
static const size_t RTC_PERSIST_SIZE =
    sizeof(RtcData) + sizeof(uint32) + RtcMemory::RTC_USER_DATA_SIZE;

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

static void load_from_flash() {
  // Read via XIP (memory-mapped flash) into the noinit variables.
  const uint8* flash_ptr = reinterpret_cast<const uint8*>(
      AP_FLASH_XIP_ADDR + RTC_FLASH_OFFSET);
  memcpy(&rtc, flash_ptr, sizeof(rtc));
  memcpy(&rtc_checksum, flash_ptr + sizeof(rtc), sizeof(rtc_checksum));
  memcpy(&rtc_user_data, flash_ptr + sizeof(rtc) + sizeof(rtc_checksum),
         sizeof(rtc_user_data));
}

static void reset_rtc(const char* reason) {
  printf("[toit] DEBUG: clearing RTC memory: %s\n", reason);
  memset(&rtc, 0, sizeof(rtc));
  memset(&rtc_user_data, 0, sizeof(rtc_user_data));
  rtc.boot_count = 1;
  update_rtc_checksum();
}

void RtcMemory::set_up() {
  // Try to restore from flash (noinit section doesn't survive HIBERNATE).
  load_from_flash();

  // Use the CRC as the primary wake detector.
  uint32 expected = compute_rtc_checksum();
  printf("[toit] DEBUG: rtc_checksum=0x%x expected=0x%x boot_count=%d\n",
         static_cast<unsigned>(rtc_checksum),
         static_cast<unsigned>(expected),
         static_cast<int>(rtc.boot_count));
  if (is_rtc_valid()) {
    rtc.boot_count++;
    update_rtc_checksum();
    printf("[toit] DEBUG: RTC memory valid (boot %d)\n",
           static_cast<int>(rtc.boot_count));
  } else {
    reset_rtc("cold boot or RTC invalid");
  }
}

void RtcMemory::flush_to_flash() {
  // Write the noinit section contents to flash as a contiguous block.
  // Use a RAM buffer since BSP_QSPI_Write_Safe requires a RAM source.
  uint8 buf[RTC_PERSIST_SIZE];
  memcpy(buf, &rtc, sizeof(rtc));
  memcpy(buf + sizeof(rtc), &rtc_checksum, sizeof(rtc_checksum));
  memcpy(buf + sizeof(rtc) + sizeof(rtc_checksum),
         rtc_user_data, sizeof(rtc_user_data));

  BSP_QSPI_Erase_Safe(RTC_FLASH_OFFSET, RTC_FLASH_SIZE);
  BSP_QSPI_Write_Safe(buf, RTC_FLASH_OFFSET, RTC_PERSIST_SIZE);
}

void RtcMemory::invalidate() {
  rtc_checksum = compute_rtc_checksum() + 1;
}

void RtcMemory::on_deep_sleep_start() {
  update_rtc_checksum();
  flush_to_flash();
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
