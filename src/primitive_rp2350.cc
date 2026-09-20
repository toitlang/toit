// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "top.h"
#ifdef TOIT_RP2350
#include "objects_inline.h"
#include "primitive.h"
#include "process.h"
#include "flash_rp2350.h"
#include "ota_image_rp2350.h"
#include "sha.h"
#include "watchdog.h"
#include "watchdog_rp2350.h"
#include "hardware/sync.h"
#include "hardware/watchdog.h"
#include "hardware/structs/powman.h"
#include "pico/bootrom.h"
#include "pico/unique_id.h"
#include "boot/picoboot_constants.h"

namespace toit {
MODULE_IMPLEMENTATION(rp2350, MODULE_RP2350)
static uint32 staged_size = 0;
static bool app_watchdog_armed = false;
static bool app_watchdog_caused_reset = false;

void initialize_rp2350_watchdog() {
  app_watchdog_caused_reset = watchdog_enable_caused_reboot();
}

PRIMITIVE(woke_from_deep_sleep) {
  // POWMAN's last power-reset latch survives PSM watchdog resets. Use the
  // raw watchdog reason: watchdog_caused_reboot() excludes OTA reboots.
  return BOOL((powman_hw->chip_reset & POWMAN_CHIP_RESET_HAD_SWCORE_PD_BITS) != 0 &&
              watchdog_hw->reason == 0);
}

PRIMITIVE(unique_id) {
  ByteArray* result = process->allocate_byte_array(PICO_UNIQUE_BOARD_ID_SIZE_BYTES);
  if (result == null) FAIL(ALLOCATION_FAILED);
  pico_unique_board_id_t id;
  // The SDK caches the OTP identity before main; this does not access flash
  // or interfere with an update running in another container.
  pico_get_unique_board_id(&id);
  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), id.id, sizeof(id.id));
  return result;
}

static bool verify_image(const rp2350::Partition& slot, uint32 size, const uint8* first = null) {
  const uint8* bytes = rp2350::flash_address(slot.offset);
  rp2350::ImageHash info;
  if (size > slot.size || !rp2350::parse_ota_image(bytes, size, &info, first)) return false;
  Sha sha(null, 256);
  for (unsigned i = 0; i < info.range_count; i++) {
    uint32 offset = info.ranges[i].offset;
    uint32 length = info.ranges[i].size;
    if (first != null && offset < 4096) {
      uint32 count = length < 4096 - offset ? length : 4096 - offset;
      sha.add(first + offset, count);
      offset += count;
      length -= count;
    }
    sha.add(bytes + offset, length);
  }
  uint8 block[384];
  if (info.block_hash_size > sizeof(block)) return false;
  memcpy(block, bytes + info.block_offset, info.block_hash_size);
  block[7] &= 0x7f;  // ROM hashing excludes the mutable TBYB flag.
  sha.add(block, info.block_hash_size);
  uint8 digest[32];
  sha.get(digest);
  return memcmp(digest, bytes + info.digest_offset, sizeof(digest)) == 0;
}

static bool boot_info(boot_info_t* info) {
  return rom_get_boot_info(info) && (info->partition == 0 || info->partition == 1);
}

static bool trial() {
  boot_info_t info = {};
  return boot_info(&info) && (info.tbyb_and_update_info & BOOT_TBYB_AND_UPDATE_FLAG_BUY_PENDING);
}

Object* platform_watchdog_start(Process* process, int timeout_ms) {
  // RP2350's 24-bit timer runs at 1 MHz. Keep the public limit at a whole
  // second below the hardware's 16.777215-second maximum.
  if (timeout_ms < 1000 || timeout_ms > 16000) FAIL(INVALID_ARGUMENT);
  // explicit_buy disables the same hardware timer. Do not let application
  // feeds extend the ROM's deadline, or validation cancel an application
  // watchdog that was armed during the trial.
  if (trial()) FAIL(INVALID_STATE);
  uint32 interrupts = save_and_disable_interrupts();
  watchdog_enable(timeout_ms, false);
  app_watchdog_armed = true;
  restore_interrupts(interrupts);
  return process->null_object();
}

Object* platform_watchdog_feed(Process* process) {
  if (app_watchdog_armed) watchdog_update();
  return process->null_object();
}

Object* platform_watchdog_stop(Process* process) {
  if (app_watchdog_armed) {
    watchdog_disable();
    app_watchdog_armed = false;
  }
  return process->null_object();
}

PRIMITIVE(watchdog_start) {
  ARGS(int, timeout_ms);
  return platform_watchdog_start(process, timeout_ms);
}

PRIMITIVE(watchdog_feed) {
  return platform_watchdog_feed(process);
}

PRIMITIVE(watchdog_stop) {
  return platform_watchdog_stop(process);
}

PRIMITIVE(watchdog_caused_reset) {
  return BOOL(app_watchdog_caused_reset);
}

static bool inactive_partition(rp2350::Partition* result) {
  boot_info_t info = {};
  rp2350::Partition a, b;
  if (!boot_info(&info) || !rp2350::firmware_pair(&a, &b)) return false;
  *result = info.partition == 0 ? b : a;
  return true;
}

PRIMITIVE(boot_partition) {
  boot_info_t info = {};
  return Smi::from(boot_info(&info) ? info.partition : -1);
}

PRIMITIVE(is_trial) {
  return BOOL(trial());
}

PRIMITIVE(validate) {
  PRIVILEGED;
  rp2350::Partition slot;
  if (!inactive_partition(&slot)) FAIL(UNSUPPORTED);
  if (!trial()) return process->null_object();
  // Allocate before invoking ROM: even a failed explicit-buy call disables
  // its watchdog. On failure, reboot so the confirmed image can recover.
  uint32* buffer = static_cast<uint32*>(malloc(4096));
  if (buffer == null) FAIL(MALLOC_FAILED);
  int result = rom_explicit_buy(reinterpret_cast<uint8*>(buffer), 4096);
  free(buffer);
  if (result != BOOTROM_OK) {
    rom_reboot(REBOOT2_FLAG_REBOOT_TYPE_NORMAL | REBOOT2_FLAG_NO_RETURN_ON_SUCCESS, 10, BOOT_PARTITION_NONE, 0);
    FAIL(ERROR);
  }
  return process->null_object();
}

PRIMITIVE(rollback) {
  PRIVILEGED;
  if (!trial()) FAIL(INVALID_ARGUMENT);
  rom_reboot(REBOOT2_FLAG_REBOOT_TYPE_NORMAL | REBOOT2_FLAG_NO_RETURN_ON_SUCCESS, 10, BOOT_PARTITION_NONE, 0);
  FAIL(ERROR);
}

PRIMITIVE(inactive_size) {
  rp2350::Partition slot;
  if (!inactive_partition(&slot)) FAIL(UNSUPPORTED);
  return Smi::from(slot.size);
}

PRIMITIVE(inactive_erase) {
  PRIVILEGED;
  ARGS(int, offset);
  if (trial()) FAIL(PERMISSION_DENIED);
  rp2350::Partition slot;
  if (!inactive_partition(&slot)) FAIL(UNSUPPORTED);
  if (offset < 0 || (offset & 4095) != 0) FAIL(INVALID_ARGUMENT);
  if (static_cast<uint32>(offset) >= slot.size) FAIL(OUT_OF_BOUNDS);
  staged_size = 0;
  if (!rp2350::flash_erase(slot.offset + offset, 4096)) FAIL(ERROR);
  return process->null_object();
}

PRIMITIVE(inactive_write) {
  PRIVILEGED;
  ARGS(int, offset, Blob, bytes);
  if (trial()) FAIL(PERMISSION_DENIED);
  rp2350::Partition slot;
  if (!inactive_partition(&slot)) FAIL(UNSUPPORTED);
  if (offset < 0 || (offset & 255) != 0 || (bytes.length() & 255) != 0) FAIL(INVALID_ARGUMENT);
  // Only stage may publish the first sector, after checking the complete
  // candidate with its header overlaid from SRAM.
  if (offset < 4096) FAIL(PERMISSION_DENIED);
  if (static_cast<uint32>(offset) > slot.size ||
      static_cast<uint32>(bytes.length()) > slot.size - offset) FAIL(OUT_OF_BOUNDS);
  staged_size = 0;
  if (!rp2350::flash_write(slot.offset + offset, bytes.address(), bytes.length())) FAIL(ERROR);
  return process->null_object();
}

PRIMITIVE(upgrade) {
  PRIVILEGED;
  if (trial()) FAIL(PERMISSION_DENIED);
  rp2350::Partition slot;
  if (staged_size == 0 || !inactive_partition(&slot)) FAIL(INVALID_STATE);
  if (!verify_image(slot, staged_size)) FAIL(INVALID_ARGUMENT);
  uint8* work = static_cast<uint8*>(malloc(4096));
  if (work == null) FAIL(MALLOC_FAILED);
  // Picking mutates ROM downgrade bookkeeping. Do it only from a confirmed
  // image, immediately before reboot, never during a pending explicit buy.
  int picked = rom_pick_ab_partition(work, 4096, 0, XIP_BASE + slot.offset);
  free(work);
  boot_info_t info = {};
  if (!boot_info(&info) || picked != 1 - info.partition) FAIL(INVALID_ARGUMENT);
  // No task may feed or stop the application watchdog after ROM repurposes
  // it for this reboot. Core 1 is unused by this port.
  uint32 interrupts = save_and_disable_interrupts();
  rom_reboot(REBOOT2_FLAG_REBOOT_TYPE_FLASH_UPDATE | REBOOT2_FLAG_REBOOT_TO_ARM |
             REBOOT2_FLAG_NO_RETURN_ON_SUCCESS, 100, XIP_BASE + slot.offset, 0);
  restore_interrupts(interrupts);
  FAIL(ERROR);
}

PRIMITIVE(stage) {
  PRIVILEGED;
  ARGS(int, size, Blob, first);
  if (trial()) FAIL(PERMISSION_DENIED);
  rp2350::Partition slot;
  staged_size = 0;
  if (!inactive_partition(&slot)) FAIL(UNSUPPORTED);
  if (size <= 0 || first.length() != 4096 ||
      !verify_image(slot, size, first.address())) FAIL(INVALID_ARGUMENT);
  if (!rp2350::flash_write(slot.offset, first.address(), first.length())) FAIL(ERROR);
  if (!verify_image(slot, size)) FAIL(ERROR);
  staged_size = size;
  return process->null_object();
}

}  // namespace toit
#endif
