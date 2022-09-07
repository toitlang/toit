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

#include <stdio.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/tcpip.h"

#include "esp_sleep.h"

#include <soc/soc.h>
#include <soc/rtc.h>

#ifndef CONFIG_IDF_TARGET_ESP32C3
  #include "soc/sens_reg.h"
#endif

#include "driver/gpio.h"
#include "driver/rtc_io.h"

#include "heap.h"
#include "process.h"
#include "memory.h"
#include "os.h"
#include "program.h"
#include "flash_registry.h"
#include "scheduler.h"
#include "rtc_memory_esp32.h"
#include "vm.h"
#include "objects_inline.h"
#include "third_party/dartino/gc_metadata.h"

extern "C" uword toit_image_table;

namespace toit {

const Program* setup_program(bool supports_ota) {
  if (supports_ota) {
#ifndef CONFIG_IDF_TARGET_ESP32C3
    const esp_partition_t* configured = esp_ota_get_boot_partition();
    const esp_partition_t* running = esp_ota_get_running_partition();

    if (configured != running) {
      ESP_LOGW("Toit", "Configured OTA boot partition at offset 0x%08x, but running from offset 0x%08x",
          configured->address, running->address);
    }

    switch (running->subtype) {
      case ESP_PARTITION_SUBTYPE_APP_FACTORY:
        ESP_LOGI("Toit", "Running from factory partition");
        break;
      case ESP_PARTITION_SUBTYPE_APP_OTA_0:
        ESP_LOGI("Toit", "Running from OTA-0 partition");
        break;
      case ESP_PARTITION_SUBTYPE_APP_OTA_1:
        ESP_LOGI("Toit", "Running from OTA-1 partition");
        break;
      default:
        ESP_LOGE("Toit", "Running from unknown partition");
        break;
    }
#endif
  }

  uword* table = &toit_image_table;
  return reinterpret_cast<const Program*>(table[1]);
}

static void start() {
  RtcMemory::set_up();
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();

  // The Toit firmware only supports OTAs if we can find the OTA app partition.
  bool supports_ota = NULL != esp_partition_find_first(
      ESP_PARTITION_TYPE_APP,
      ESP_PARTITION_SUBTYPE_APP_OTA_MIN,
      NULL);

  // Determine if we're running from a non-boot image chosen by the bootloader.
  // This seems to happen when the bootloader detects that the boot image is
  // damaged, so it decides to boot the other one.
  bool firmware_rejected = supports_ota &&
      esp_ota_get_boot_partition() != esp_ota_get_running_partition();

  const Program* program = setup_program(supports_ota);
  Scheduler::ExitState exit_state;
  { VM vm;
    vm.load_platform_event_sources();
    int group_id = vm.scheduler()->next_group_id();
    exit_state = vm.scheduler()->run_boot_program(const_cast<Program*>(program), group_id);
  }

  GcMetadata::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();

  // Determine if the firmware has been updated. We update the boot partition
  // when a new firmware has been installed, so if we're not in a situation
  // where the boot image was rejected and the boot image has changed as part
  // of running the VM, we consider it a firmware update.
  bool firmware_updated = !firmware_rejected && supports_ota &&
      esp_ota_get_boot_partition() != esp_ota_get_running_partition();

  if (firmware_updated) {
    // If we're updating the firmware, we call esp_restart to ensure we fully
    // reset the chip with the new firmware.
    ets_printf("Firmware updated; doing chip reset\n");
    esp_restart();  // Careful: This clears the RTC memory.
  }

  switch (exit_state.reason) {
    case Scheduler::EXIT_DEEP_SLEEP: {
      const int64 MIN_MS = 50;
      const int64 MAX_MS = 1 * 24 * 60 * 60 * 1000;  // 1 day.
      int64 ms = exit_state.value;
      if (ms < MIN_MS) ms = MIN_MS;
      else if (ms > MAX_MS) ms = MAX_MS;
      ets_printf("Entering deep sleep for %lldms\n", ms);
      err_t err = esp_sleep_enable_timer_wakeup(ms * 1000);
      if (err != ERR_OK) FATAL("Cannot enable deep sleep timer");
      break;
    }

    case Scheduler::EXIT_ERROR:
#ifndef CONFIG_IDF_TARGET_ESP32C3
      ESP_LOGE("Toit", "VM exited with error, restarting.");
#endif
      // 1s sleep before restart, after an error.
      esp_sleep_enable_timer_wakeup(1000000);
      break;

    case Scheduler::EXIT_DONE:
#ifndef CONFIG_IDF_TARGET_ESP32C3
      ESP_LOGE("Toit", "VM exited, going into deep sleep.");
#endif
      break;

    case Scheduler::EXIT_NONE:
      UNREACHABLE();
  }

  RtcMemory::before_deep_sleep();
  esp_deep_sleep_start();
}

} // namespace toit

extern "C" void toit_start() {
  toit::start();
}

#endif // TOIT_FREERTOS
