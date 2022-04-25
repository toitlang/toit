// Copyright (C) 2018 Toitware ApS.
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

#ifdef TOIT_FREERTOS

#include "flash_allocation.h"
#include "objects_inline.h"
#include "os.h"
#include "primitive.h"
#include "process.h"
#include "scheduler.h"
#include "sha1.h"
#include "sha256.h"

#include "rtc_memory_esp32.h"

#include "uuid.h"
#include "vm.h"

#include <math.h>
#include <unistd.h>
#include <sys/types.h> /* See NOTES */
#include <errno.h>
#include <atomic>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include <driver/adc.h>
#include <driver/rtc_io.h>
#include <esp_adc_cal.h>
#include <esp_log.h>
#include <esp_sleep.h>
#include <esp_ota_ops.h>
#include <esp_spi_flash.h>
#include <esp_timer.h>

#include <soc/rtc_cntl_reg.h>

#ifdef CONFIG_IDF_TARGET_ESP32C3
//  #include <soc/esp32/include/soc/sens_reg.h>
  #include <esp32c3/rom/rtc.h>
  #include <esp32c3/rom/ets_sys.h>
#else
  #include <soc/sens_reg.h>
  #include <esp32/rom/rtc.h>
  #include <esp32/rom/ets_sys.h>
  #include <driver/touch_sensor.h>
  #include <esp32/ulp.h>
#endif

#include "esp_partition.h"
#include "esp_spi_flash.h"

#include "event_sources/system_esp32.h"

namespace toit {

MODULE_IMPLEMENTATION(esp32, MODULE_ESP32)

static const esp_partition_t* ota_partition = null;
static int ota_size = 0;
static int ota_written = 0;

PRIMITIVE(ota_begin) {
  PRIVILEGED;
  ARGS(int, from, int, to);
  if (!(0 <= from && from < to)) {
    ESP_LOGE("Toit", "Unordered ota_begin args: %d-%d", from, to);
    INVALID_ARGUMENT;
  }

  ota_partition = esp_ota_get_next_update_partition(null);
  if (ota_partition == null) {
    ESP_LOGE("Toit", "Cannot find OTA partition - retrying after GC");
    // This can actually be caused by a malloc failure in the
    // esp-idf libraries.
    MALLOC_FAILED;
  }

  if (to > ota_partition->size) {
    ESP_LOGE("Toit", "Oversized ota_begin args: %d-%d", to, ota_partition->size);
    OUT_OF_BOUNDS;
  }

  ota_size = to;
  ota_written = from;
  return process->program()->null_object();
}

PRIMITIVE(ota_write) {
  PRIVILEGED;
  ARGS(Blob, bytes);

  if (ota_partition == null) {
    ESP_LOGE("Toit", "Cannot write to OTA session before starting it");
    OUT_OF_BOUNDS;
  }

  if (bytes.length() == FLASH_PAGE_SIZE && ota_written == Utils::round_up(ota_written, FLASH_PAGE_SIZE)) {
    // Common case - we are page aligned and asked to write one page.
    // We optimize for the case where this page is already what we want.
    // This tends to happen when developing and you change versions several
    // times and only the Toit code in the image changes.
    bool identical = true;
    uint8 buffer[64];
    for (int i = 0; identical && i < FLASH_PAGE_SIZE; i += 64) {
      esp_err_t err = esp_partition_read(ota_partition, ota_written + i, buffer, 64);
      if (err != ESP_OK || memcmp(buffer, bytes.address() + i, 64) != 0) {
        identical = false;
      }
    }
    if (identical) {
      ota_written += FLASH_PAGE_SIZE;
      return Smi::from(ota_written);
    }
  }

  // The last OTA is the only one that is allowed to not be divisible
  // by 16.
  if (ota_written != Utils::round_up(ota_written, FLASH_SEGMENT_SIZE)) {
    ESP_LOGE("Toit", "More OTA was written after last block");
    OUT_OF_BOUNDS;
  }

  if (ota_size > 0 && (ota_written + bytes.length() > ota_size)) {
    ESP_LOGE("Toit", "OTA write overflows predetermined size (%d + %d > %d)",
        ota_written, bytes.length(), ota_size);
    OUT_OF_BOUNDS;
  }

  uword to_write = Utils::round_down(bytes.length(), FLASH_SEGMENT_SIZE);

  word erase_from = Utils::round_up(ota_written, FLASH_PAGE_SIZE);
  word erase_to = Utils::round_up(ota_written + to_write, FLASH_PAGE_SIZE);
  for (word page = erase_from; page < erase_to; page += FLASH_PAGE_SIZE) {
    esp_err_t err = esp_partition_erase_range(ota_partition, page, FLASH_PAGE_SIZE);
    if (err != ESP_OK) {
      ota_partition = null;
      ESP_LOGE("Toit", "esp_partition_erase_range failed (%s)", esp_err_to_name(err));
      OUT_OF_BOUNDS;
    }
  }

  esp_err_t err = esp_partition_write(ota_partition, ota_written, reinterpret_cast<const void*>(bytes.address()), to_write);

  if (err == ESP_OK && to_write != bytes.length()) {
    // Last write can be a non-multiple of 16.  We pad it up.
    uint8 temp_buffer[FLASH_SEGMENT_SIZE];
    memset(temp_buffer, 0, FLASH_SEGMENT_SIZE);
    memcpy(temp_buffer, bytes.address() + to_write, bytes.length() - to_write);
    err = esp_partition_write(ota_partition, ota_written, reinterpret_cast<const void*>(temp_buffer), bytes.length() - to_write);
  }

  if (err != ESP_OK) {
    ESP_LOGE("Toit", "esp_partition_write failed (%s)!", esp_err_to_name(err));
    ota_partition = null;
    OUT_OF_BOUNDS;
  }

  ota_written += bytes.length();
  return Smi::from(ota_written);
}

PRIMITIVE(ota_end) {
  PRIVILEGED;
  ARGS(int, size, Object, expected);
  esp_err_t err = ESP_OK;

  const int BLOCK = 1024;
  AllocationManager allocation(process);
  uint8* buffer = allocation.alloc(BLOCK);
  if (buffer == null) ALLOCATION_FAILED;

  if (size != 0) {
    if (ota_partition == null) {
      ESP_LOGE("Toit", "Cannot end OTA session before starting it");
      OUT_OF_BOUNDS;
    }

    ASSERT(ota_size == 0 || (ota_written <= ota_size));
    if (ota_size > 0 && ota_written < ota_size) {
      ESP_LOGE("Toit", "OTA only partially written (%d < %d)", ota_written, ota_size);
      OUT_OF_BOUNDS;
    }

    const esp_partition_pos_t partition_position = {
      ota_partition->address,
      ota_partition->size
    };

    esp_image_metadata_t image_metadata;

    err = esp_image_verify(ESP_IMAGE_VERIFY, &partition_position, &image_metadata);
    if (err != ESP_OK) {
      ESP_LOGE("Toit", "esp_image_verify failed (%s)!", esp_err_to_name(err));
      ota_partition = null;
      OUT_OF_BOUNDS;
    }

    // The system SHA256 checksum is optional, so we add an explicit verification
    // that we control.  (There is also a non-optional checksum, but it is only one
    // byte, and so not really reliable.)
    Blob checksum_bytes;
    if (expected->byte_content(process->program(), &checksum_bytes, STRINGS_OR_BYTE_ARRAYS)) {
      if (checksum_bytes.length() != Sha256::HASH_LENGTH) INVALID_ARGUMENT;
      Sha256 sha(null);
      for (int i = 0; i < size; i += BLOCK) {
        int chunk = Utils::min(BLOCK, size - i);
        err = esp_partition_read(ota_partition, i, buffer, chunk);
        if (err != ESP_OK) OUT_OF_BOUNDS;
        sha.add(buffer, chunk);
      }
      uint8 calculated[Sha256::HASH_LENGTH];
      sha.get(calculated);
      int diff = 0;
      for (int i = 0; i < Sha256::HASH_LENGTH; i++) {
        diff |= calculated[i] ^ checksum_bytes.address()[i];
      }
      if (diff != 0) {
        ESP_LOGE("Toit", "esp_image_verify failed!");
        ota_partition = null;
        OUT_OF_BOUNDS;
      }
    }

    err = esp_ota_set_boot_partition(ota_partition);
  }

  ota_partition = null;
  ota_size = 0;
  ota_written = 0;

  if (err != ESP_OK) {
    ESP_LOGE("Toit", "esp_ota_set_boot_partition failed (%s)!", esp_err_to_name(err));
    OUT_OF_BOUNDS;
  }
  return Smi::zero();
}

PRIMITIVE(reset_reason) {
  return Smi::from(esp_reset_reason());
}

PRIMITIVE(total_deep_sleep_time) {
  return Primitive::integer(RtcMemory::total_deep_sleep_time(), process);
}

PRIMITIVE(enable_external_wakeup) {
#ifndef CONFIG_IDF_TARGET_ESP32C3
  ARGS(int64, pin_mask, bool, on_any_high);
  esp_err_t err = esp_sleep_enable_ext1_wakeup(pin_mask, on_any_high ? ESP_EXT1_WAKEUP_ANY_HIGH : ESP_EXT1_WAKEUP_ALL_LOW);
  if (err != ESP_OK) {
    ESP_LOGE("Toit", "Failed: sleep_enable_ext1_wakeup");
    OTHER_ERROR;
  }
#endif
  return process->program()->null_object();
}

PRIMITIVE(wakeup_cause) {
  return Smi::from(esp_sleep_get_wakeup_cause());
}

PRIMITIVE(ext1_wakeup_status) {
#ifndef CONFIG_IDF_TARGET_ESP32C3
  ARGS(int64, pin_mask);
  uint64 status = esp_sleep_get_ext1_wakeup_status();
  for (int pin = 0; pin_mask > 0; pin++) {
    if (pin_mask & 1) rtc_gpio_deinit(static_cast<gpio_num_t>(pin));
    pin_mask >>= 1;
  }
  return Primitive::integer(status, process);
#else
  return process->program()->null_object();
#endif
}

PRIMITIVE(total_run_time) {
  return Primitive::integer(RtcMemory::total_run_time(), process);
}

PRIMITIVE(image_config) {
  size_t length;
  // TODO(anders): We would prefer to do a read-only view.
  uint8* config = OS::image_config(&length);
  ByteArray* result = process->object_heap()->allocate_proxy(length, config);
  if (result == null) ALLOCATION_FAILED;
  return result;
}

PRIMITIVE(get_mac_address) {
  Error* error = null;
  ByteArray* result = process->allocate_byte_array(6, &error);
  if (result == null) return error;

  ByteArray::Bytes bytes = ByteArray::Bytes(result);
  esp_err_t err = esp_efuse_mac_get_default(bytes.address());
  if (err != ESP_OK) memset(bytes.address(), 0, 6);

  return result;
}

PRIMITIVE(rtc_user_bytes) {
  uint8* rtc_memory = RtcMemory::user_data_address();
  Error* error = null;
  ByteArray* result = process->object_heap()->allocate_external_byte_array(RtcMemory::RTC_USER_DATA_SIZE, rtc_memory, false, false);
  if (result == null) return error;

  return result;
}

} // namespace toit

#endif // TOIT_FREERTOS
