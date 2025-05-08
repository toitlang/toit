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

#ifdef TOIT_ESP32

#include "flash_allocation.h"
#include "objects_inline.h"
#include "os.h"
#include "primitive.h"
#include "process.h"
#include "scheduler.h"
#include "sha1.h"
#include "sha.h"

#include "rtc_memory_esp32.h"

#include "uuid.h"
#include "vm.h"

#include <atomic>
#include <errno.h>
#include <math.h>
#include <sys/types.h> /* See NOTES */
#include <unistd.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include <driver/rtc_io.h>
#include <esp_image_format.h>
#include <esp_log.h>
#include <esp_mac.h>
#include <esp_sleep.h>
#include <esp_ota_ops.h>
#include <esp_pm.h>
#include <esp_timer.h>
#include <rom/ets_sys.h>
#include <esp_task_wdt.h>

#include <driver/gpio.h>

#if SOC_TOUCH_SENSOR_SUPPORTED
#include <driver/touch_pad.h>
#endif
#if CONFIG_IDF_TARGET_ESP32
  #include <soc/sens_reg.h>
  #include <esp32/rom/rtc.h>
#elif CONFIG_IDF_TARGET_ESP32C3
  #include <esp32c3/rom/rtc.h>
#elif CONFIG_IDF_TARGET_ESP32C6
  #include <esp32c6/rom/rtc.h>
#elif CONFIG_IDF_TARGET_ESP32S2
  #include <esp32s2/rom/rtc.h>
#elif CONFIG_IDF_TARGET_ESP32S3
  #include <esp32s3/rom/rtc.h>
#else
  #error Unknown ESP32 target architecture
#endif

#include "esp_partition.h"

#include "event_sources/system_esp32.h"
#include "resource.h"
#include "resource_pool.h"
#include "resources/touch_esp32.h"

namespace toit {

const int kInvalidWatchdogTimer = -1;
const int kWatchdogSingletonId = 0;
ResourcePool<int, kInvalidWatchdogTimer> watchdog_timers(
  kWatchdogSingletonId
);

class PmLockResource : public Resource {
 public:
  TAG(PmLockResource);
  PmLockResource(SimpleResourceGroup* group, esp_pm_lock_handle_t handle, char* name)
      : Resource(group)
      , handle_(handle)
      , name_(name) {}
  ~PmLockResource() override;

  esp_pm_lock_handle_t handle() const { return handle_; }
  void increase_count() { count_++; }
  void decrease_count() { count_--; }

 private:
  esp_pm_lock_handle_t handle_;
  char* name_;
  int count_ = 0;
};

PmLockResource::~PmLockResource() {
  for (int i = 0; i < count_; i++) {
    FATAL_IF_NOT_ESP_OK(esp_pm_lock_release(handle_));
  }
  FATAL_IF_NOT_ESP_OK(esp_pm_lock_delete(handle_));
  free(name_);
}

MODULE_IMPLEMENTATION(esp32, MODULE_ESP32)

enum {
  OTA_STATE_VALIDATION_PENDING = 1 << 0,
  OTA_STATE_ROLLBACK_POSSIBLE  = 1 << 1,
};

static const esp_partition_t* ota_partition = null;
static int ota_size = 0;
static int ota_written = 0;

PRIMITIVE(ota_current_partition_name) {
  const esp_partition_t* current_partition = esp_ota_get_running_partition();
  if (current_partition == null) FAIL(ERROR);
  return process->allocate_string_or_error(current_partition->label);
}

PRIMITIVE(ota_begin) {
  PRIVILEGED;
  ARGS(int, from, int, to);
  if (!(0 <= from && from < to)) {
    ESP_LOGE("Toit", "Unordered ota_begin args: %d-%d", from, to);
    FAIL(INVALID_ARGUMENT);
  }

  ota_partition = esp_ota_get_next_update_partition(null);
  if (ota_partition == null) {
    ESP_LOGE("Toit", "Cannot find OTA partition - retrying after GC");
    // This can actually be caused by a malloc failure in the
    // esp-idf libraries.
    FAIL(MALLOC_FAILED);
  }

  if (to > ota_partition->size) {
    ESP_LOGE("Toit", "Oversized ota_begin args: %d-%" PRId32, to, ota_partition->size);
    FAIL(OUT_OF_BOUNDS);
  }

  ota_size = to;
  ota_written = from;
  return process->null_object();
}

PRIMITIVE(ota_write) {
  PRIVILEGED;
  ARGS(Blob, bytes);

  if (ota_partition == null) {
    ESP_LOGE("Toit", "Cannot write to OTA session before starting it");
    FAIL(OUT_OF_BOUNDS);
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
    FAIL(OUT_OF_BOUNDS);
  }

  if (ota_size > 0 && (ota_written + bytes.length() > ota_size)) {
    ESP_LOGE("Toit", "OTA write overflows predetermined size (%d + %d > %d)",
        ota_written, bytes.length(), ota_size);
    FAIL(OUT_OF_BOUNDS);
  }

  uword to_write = Utils::round_down(bytes.length(), FLASH_SEGMENT_SIZE);

  word erase_from = Utils::round_up(ota_written, FLASH_PAGE_SIZE);
  word erase_to = Utils::round_up(ota_written + to_write, FLASH_PAGE_SIZE);
  for (word page = erase_from; page < erase_to; page += FLASH_PAGE_SIZE) {
    esp_err_t err = esp_partition_erase_range(ota_partition, page, FLASH_PAGE_SIZE);
    if (err != ESP_OK) {
      ota_partition = null;
      ESP_LOGE("Toit", "esp_partition_erase_range failed (%s)", esp_err_to_name(err));
      FAIL(OUT_OF_BOUNDS);
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
    FAIL(OUT_OF_BOUNDS);
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
  if (buffer == null) FAIL(ALLOCATION_FAILED);

  Sha* sha256 = _new Sha(null, 256);
  if (sha256 == null) FAIL(ALLOCATION_FAILED);
  DeferDelete<Sha> d(sha256);

  if (size != 0) {
    if (ota_partition == null) {
      ESP_LOGE("Toit", "Cannot end OTA session before starting it");
      FAIL(OUT_OF_BOUNDS);
    }

    ASSERT(ota_size == 0 || (ota_written <= ota_size));
    if (ota_size > 0 && ota_written < ota_size) {
      ESP_LOGE("Toit", "OTA only partially written (%d < %d)", ota_written, ota_size);
      FAIL(OUT_OF_BOUNDS);
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
      FAIL(OUT_OF_BOUNDS);
    }

    // The system SHA256 checksum is optional, so we add an explicit verification
    // that we control.  (There is also a non-optional checksum, but it is only one
    // byte, and so not really reliable.)
    Blob checksum_bytes;
    if (expected->byte_content(process->program(), &checksum_bytes, STRINGS_OR_BYTE_ARRAYS)) {
      if (checksum_bytes.length() != Sha::HASH_LENGTH_256) FAIL(INVALID_ARGUMENT);
      for (int i = 0; i < size; i += BLOCK) {
        int chunk = Utils::min(BLOCK, size - i);
        err = esp_partition_read(ota_partition, i, buffer, chunk);
        if (err != ESP_OK) FAIL(OUT_OF_BOUNDS);
        sha256->add(buffer, chunk);
      }
      uint8 calculated[Sha::HASH_LENGTH_256];
      sha256->get(calculated);
      int diff = 0;
      for (int i = 0; i < Sha::HASH_LENGTH_256; i++) {
        diff |= calculated[i] ^ checksum_bytes.address()[i];
      }
      if (diff != 0) {
        ESP_LOGE("Toit", "esp_image_verify failed!");
        ota_partition = null;
        FAIL(OUT_OF_BOUNDS);
      }
    }

    err = esp_ota_set_boot_partition(ota_partition);
  }

  ota_partition = null;
  ota_size = 0;
  ota_written = 0;

  if (err != ESP_OK) {
    ESP_LOGE("Toit", "esp_ota_set_boot_partition failed (%s)!", esp_err_to_name(err));
    FAIL(OUT_OF_BOUNDS);
  }
  return Smi::zero();
}

static bool is_validation_pending() {
  const esp_partition_t* running = esp_ota_get_running_partition();
  esp_ota_img_states_t ota_state;
  esp_err_t err = esp_ota_get_state_partition(running, &ota_state);
  // If we are running from the factory partition esp_ota_get_state_partition fails.
  return (err == ESP_OK && ota_state == ESP_OTA_IMG_PENDING_VERIFY);
}

PRIMITIVE(ota_state) {
  int state = 0;
  if (esp_ota_check_rollback_is_possible()) state |= OTA_STATE_ROLLBACK_POSSIBLE;
  if (is_validation_pending()) state |= OTA_STATE_VALIDATION_PENDING;
  return Smi::from(state);
}

PRIMITIVE(ota_validate) {
  if (!is_validation_pending()) return BOOL(false);
  esp_err_t err = esp_ota_mark_app_valid_cancel_rollback();
  return BOOL(err == ESP_OK);
}

PRIMITIVE(ota_rollback) {
  PRIVILEGED;
  bool is_rollback_possible = esp_ota_check_rollback_is_possible();
  if (!is_rollback_possible) FAIL(PERMISSION_DENIED);
  RtcMemory::invalidate();   // Careful: This clears the RTC memory on boot.
  esp_err_t err = esp_ota_mark_app_invalid_rollback_and_reboot();
  ESP_LOGE("Toit", "esp_ota_end esp_ota_mark_app_invalid_rollback_and_reboot (%s)!", esp_err_to_name(err));
  FAIL(ERROR);
}

PRIMITIVE(reset_reason) {
  return Smi::from(esp_reset_reason());
}

PRIMITIVE(total_deep_sleep_time) {
  return Primitive::integer(RtcMemory::accumulated_deep_sleep_time_us(), process);
}

PRIMITIVE(enable_external_wakeup) {
#if SOC_PM_SUPPORT_EXT1_WAKEUP
  ARGS(int64, pin_mask, bool, on_any_high);
  esp_err_t err = esp_sleep_enable_ext1_wakeup(pin_mask, on_any_high ? ESP_EXT1_WAKEUP_ANY_HIGH : ESP_EXT1_WAKEUP_ALL_LOW);
  if (err != ESP_OK) {
    ESP_LOGE("Toit", "Failed: sleep_enable_ext1_wakeup");
    FAIL(ERROR);
  }
#else
  FAIL(UNSUPPORTED);
#endif
  return process->null_object();
}

PRIMITIVE(enable_touchpad_wakeup) {
#if SOC_TOUCH_SENSOR_SUPPORTED
  esp_err_t err = esp_sleep_enable_touchpad_wakeup();
  if (err != ESP_OK) {
    ESP_LOGE("Toit", "Failed: sleep_enable_touchpad_wakeup");
    FAIL(ERROR);
  }
  err = esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_ON);
  if (err != ESP_OK) {
    ESP_LOGE("Toit", "Failed: sleep_enable_touchpad_wakeup - power domain");
    FAIL(ERROR);
  }
  keep_touch_active();
#else
  FAIL(UNSUPPORTED);
#endif
  return process->null_object();
}

PRIMITIVE(wakeup_cause) {
  return Smi::from(esp_sleep_get_wakeup_cause());
}

PRIMITIVE(ext1_wakeup_status) {
#if SOC_PM_SUPPORT_EXT1_WAKEUP
  ARGS(int64, pin_mask);
  uint64 status = esp_sleep_get_ext1_wakeup_status();
  for (int pin = 0; pin_mask > 0; pin++) {
    if (pin_mask & 1) rtc_gpio_deinit(static_cast<gpio_num_t>(pin));
    pin_mask >>= 1;
  }
  return Primitive::integer(status, process);
#else
  return Smi::from(-1);
#endif
}

PRIMITIVE(touchpad_wakeup_status) {
#if SOC_TOUCH_SENSOR_SUPPORTED
  touch_pad_t pad = esp_sleep_get_touchpad_wakeup_status();
  return Primitive::integer(touch_pad_to_pin_num(pad), process);
#else
  return Smi::from(-1);
#endif
}

PRIMITIVE(get_mac_address) {
  ByteArray* result = process->allocate_byte_array(6);
  if (result == null) FAIL(ALLOCATION_FAILED);

  ByteArray::Bytes bytes = ByteArray::Bytes(result);
  esp_err_t err = esp_efuse_mac_get_default(bytes.address());
  if (err != ESP_OK) memset(bytes.address(), 0, 6);

  return result;
}

class PageReport {
 public:
  PageReport(uword base, uword size) {
    memory_base_ = Utils::round_down(base, GRANULARITY);
    memory_size_ = Utils::round_up(size + base - memory_base_, GRANULARITY);
    memset(pages_, 0, sizeof(pages_));
  }

  void page_register_allocation(uword raw_tag, uword address, uword size) {
    if (size == 0) return;
    if (address < memory_base_) {
      return;
    }
    if (address + size > memory_base_ + PAGES * GRANULARITY) {
      return;
    }
    int page = (address - memory_base_) >> GRANULARITY_LOG2;
    int end_page = (address + size - 1 - memory_base_) >> GRANULARITY_LOG2;
    int tag = compute_allocation_type(raw_tag);
    for (int i = page; i <= end_page; i++) {
      uword flags = pages_[i] & FLAG_MASK;
      flags |= MALLOC_MANAGED;
      if (i != end_page) flags |= MERGE_WITH_NEXT;
      if (tag == TOIT_HEAP_MALLOC_TAG) flags |= TOIT;
      else if (tag == WIFI_MALLOC_TAG) flags |= BUFFERS;
      else if (tag == LWIP_MALLOC_TAG) flags |= BUFFERS;
      else if (tag == EXTERNAL_BYTE_ARRAY_MALLOC_TAG) flags |= EXTERNAL;
      else if (tag == EXTERNAL_STRING_MALLOC_TAG) flags |= EXTERNAL;
      else if (tag == BIGNUM_MALLOC_TAG) flags |= TLS;
      else if (tag != HEAP_OVERHEAD_MALLOC_TAG && tag != FREE_MALLOC_TAG) flags |= MISC;
      uword allocated = fullness(i);
      if (tag != FREE_MALLOC_TAG) {
        uword page_start = memory_base_ + i * GRANULARITY;
        uword page_end = page_start + GRANULARITY;
        uword start = Utils::max(page_start, address);
        uword end = Utils::min(page_end, address + size);
        uword overlapping_size = end - start;
        allocated = Utils::min(MAX_RECORDABLE_SIZE, allocated + overlapping_size);
      }
      pages_[i] = flags | shifted_fullness(allocated);
    }
  }

  int number_of_pages() const { return PAGES; }

  uint8 get_tag(int i) const {
    return pages_[i] & ((1 << SIZE_SHIFT_LEFT) - 1);
  }

  uint8 get_fullness(int i) const {
    uword f = fullness(i);
    if (f == MAX_RECORDABLE_SIZE) {
      return 100;
    } else {
      return (f * 100) / GRANULARITY;
    }
  }

  uword memory_base() const { return memory_base_; }

  void next_memory_base() {
    memory_base_ += GRANULARITY * PAGES;
    memset(pages_, 0, sizeof(pages_));
  }

  uword iterations_needed() const {
    return (memory_size_ + GRANULARITY * PAGES - 1) / (GRANULARITY * PAGES);
  }

  static const int GRANULARITY_LOG2 = TOIT_PAGE_SIZE_LOG2;
  static const uword GRANULARITY = 1 << GRANULARITY_LOG2;
  static const uword MASK = GRANULARITY - 1;

 private:
  uword fullness(int i) const {
    return (pages_[i] >> SIZE_SHIFT_LEFT) << SIZE_SHIFT_RIGHT;
  }

  static uword shifted_fullness(uword fullness) {
    return (fullness >> SIZE_SHIFT_RIGHT) << SIZE_SHIFT_LEFT;
  }

  static const int PAGES = 100;
  uword memory_base_;
  uword memory_size_;
  // The first 7 bits are flags, then there are 9 bits that count the number of
  // bytes that are allocated in the page.  Since all allocations are a
  // multiple of 8 this gives us a range of up to 4088 allocated bytes.
#if TOIT_PAGE_SIZE <= 4096
  uint16 pages_[PAGES];
#else
  uint32 pages_[PAGES];
#endif
  bool more_above_ = false;

  static const int MALLOC_MANAGED  = 1 << 0;
  static const int TOIT            = 1 << 1;
  static const int EXTERNAL        = 1 << 2;
  static const int TLS             = 1 << 3;
  static const int BUFFERS         = 1 << 4;
  static const int MISC            = 1 << 5;
  static const int MERGE_WITH_NEXT = 1 << 6;
  static const int SIZE_SHIFT_LEFT =      7;
  static const uword FLAG_MASK     = (1 << SIZE_SHIFT_LEFT) - 1;
  static const int SIZE_SHIFT_RIGHT = 3;  // All sizes are divisible by 8.
  static const uword MAX_RECORDABLE_SIZE = ((1 << (sizeof(pages_[0]) * BYTE_BIT_SIZE - SIZE_SHIFT_LEFT)) - 1) << SIZE_SHIFT_RIGHT;
};

bool page_register_allocation(void* self, void* tag, void* address, uword size) {
  auto report = reinterpret_cast<PageReport*>(self);
  report->page_register_allocation(
      reinterpret_cast<uword>(tag),
      reinterpret_cast<uword>(address),
      size);
  return false;
}

PRIMITIVE(memory_page_report) {
  OS::HeapMemoryRange range = OS::get_heap_memory_range();
  PageReport report(reinterpret_cast<uword>(range.address), range.size);
  MallocedBuffer buffer(4096);
  ProgramOrientedEncoder encoder(process->program(), &buffer);
  encoder.write_header(report.iterations_needed() * 3 + 1, 'M');
  int flags = ITERATE_ALL_ALLOCATIONS | ITERATE_UNALLOCATED;
  int caps = OS::toit_heap_caps_flags_for_heap();
  for (uword iteration = 0; iteration < report.iterations_needed(); iteration++) {
    heap_caps_iterate_tagged_memory_areas(&report, null, &page_register_allocation, flags, caps);
    uword size = report.number_of_pages();
    encoder.write_byte_array_header(size);
    for (int i = 0; i < size; i++) encoder.write_byte(report.get_tag(i));
    encoder.write_byte_array_header(size);
    for (int i = 0; i < size; i++) encoder.write_byte(report.get_fullness(i));
    encoder.write_int(report.memory_base());
    report.next_memory_base();
  }
  encoder.write_int(report.GRANULARITY);
  if (buffer.has_overflow()) FAIL(OUT_OF_BOUNDS);
  ByteArray* result = process->allocate_byte_array(buffer.size());
  if (result == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), buffer.content(), buffer.size());
  return result;
}

PRIMITIVE(watchdog_init) {
  ARGS(uint32, ms);

  int watchdog = watchdog_timers.any();
  if (watchdog == kInvalidWatchdogTimer) FAIL(ALREADY_IN_USE);

  esp_task_wdt_config_t config = {
    .timeout_ms = ms,
    .idle_core_mask = 0,
    .trigger_panic = true,
  };
  esp_err_t err = esp_task_wdt_init(&config);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  SystemEventSource::instance()->run([&]() {
    err = esp_task_wdt_add(null);  // Add the SystemEventSource thread.
  });
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }
  return process->null_object();
}

PRIMITIVE(watchdog_reset) {
  esp_err_t err;
  SystemEventSource::instance()->run([&]() {
    err = esp_task_wdt_reset();
  });
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }
  return process->null_object();
}

PRIMITIVE(watchdog_deinit) {
  esp_err_t err;
  SystemEventSource::instance()->run([&]() {
    err = esp_task_wdt_delete(null);  // Remove the SystemEventSource thread.
  });
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }
  err = esp_task_wdt_deinit();
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }
  watchdog_timers.put(kWatchdogSingletonId);
  return process->null_object();
}

PRIMITIVE(pin_hold_enable) {
  ARGS(int, num);
  esp_err_t err = gpio_hold_en(static_cast<gpio_num_t>(num));
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }
  return process->null_object();
}

PRIMITIVE(pin_hold_disable) {
  ARGS(int, num);
  esp_err_t err = gpio_hold_dis(static_cast<gpio_num_t>(num));
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }
  return process->null_object();
}

PRIMITIVE(deep_sleep_pin_hold_enable) {
#if !SOC_GPIO_SUPPORT_HOLD_SINGLE_IO_IN_DSLP
  gpio_deep_sleep_hold_en();
  return process->null_object();
#else
  FAIL(UNSUPPORTED);
#endif
}

PRIMITIVE(deep_sleep_pin_hold_disable) {
#if !SOC_GPIO_SUPPORT_HOLD_SINGLE_IO_IN_DSLP
  gpio_deep_sleep_hold_dis();
  return process->null_object();
#else
  FAIL(UNSUPPORTED);
#endif
}

PRIMITIVE(pm_configure) {
  ARGS(int, max_freq_mhz, int, min_freq_mhz, bool, light_sleep_enable)
#ifndef CONFIG_PM_ENABLE
  USE(max_freq_mhz);
  USE(min_freq_mhz);
  USE(light_sleep_enable);
  FAIL(UNSUPPORTED);
#else
  esp_pm_config_t cfg = {
    .max_freq_mhz = max_freq_mhz,
    .min_freq_mhz = min_freq_mhz,
    .light_sleep_enable = light_sleep_enable,
  };

  esp_err_t err = esp_pm_configure(&cfg);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->null_object();
#endif
}

PRIMITIVE(pm_get_configuration) {
#ifndef CONFIG_PM_ENABLE
  FAIL(UNSUPPORTED);
#else
  Array* array = process->object_heap()->allocate_array(3, Smi::zero());
  if (array == null) FAIL(ALLOCATION_FAILED);

  esp_pm_config_t cfg;
  esp_err_t err = esp_pm_get_configuration(&cfg);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  array->at_put(0, Smi::from(cfg.max_freq_mhz));
  array->at_put(1, Smi::from(cfg.min_freq_mhz));
  array->at_put(2, BOOL(cfg.light_sleep_enable));
  return array;
#endif
}

PRIMITIVE(pm_lock_new) {
  ARGS(SimpleResourceGroup, group, int, lock_type_value, cstring, name);

  esp_pm_lock_type_t lock_type;
  switch (lock_type_value) {
    case 0: lock_type = ESP_PM_CPU_FREQ_MAX; break;
    case 1: lock_type = ESP_PM_APB_FREQ_MAX; break;
    case 2: lock_type = ESP_PM_NO_LIGHT_SLEEP; break;
    default: FAIL(INVALID_ARGUMENT);
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  bool handed_to_resource = false;

  esp_pm_lock_handle_t handle;
  esp_err_t err = esp_pm_lock_create(lock_type, 0, name, &handle);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer release_lock { [&] { if (!handed_to_resource) esp_pm_lock_release(handle); } };

  auto resource = _new PmLockResource(group, handle, const_cast<char*>(name));
  if (resource == null) FAIL(ALLOCATION_FAILED);
  handed_to_resource = true;
  // Hack: the `cstring` type above did a copy of the Toit string.
  // We now tell the allocation manager to keep the string alive.
  _manager_name.keep_result();

  group->register_resource(resource);
  proxy->set_external_address(resource);

  return proxy;
}

PRIMITIVE(pm_lock_del) {
  ARGS(PmLockResource, resource);

  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(pm_lock_acquire) {
  ARGS(PmLockResource, resource);

  esp_err_t err = esp_pm_lock_acquire(resource->handle());
  if (err != ESP_OK) return Primitive::os_error(err, process);
  resource->increase_count();

  return process->null_object();
}

PRIMITIVE(pm_lock_release) {
  ARGS(PmLockResource, resource);

  esp_err_t err = esp_pm_lock_release(resource->handle());
  if (err != ESP_OK) return Primitive::os_error(err, process);
  resource->decrease_count();

  return process->null_object();
}

PRIMITIVE(pm_locks_dump) {
  esp_err_t err = esp_pm_dump_locks(stdout);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->null_object();
}

} // namespace toit

#endif // TOIT_FREERTOS
