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

#include <stdio.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "rom/ets_sys.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/tcpip.h"

#include "esp_sleep.h"

#include <soc/soc.h>
#include <soc/rtc.h>

#include "driver/gpio.h"
#include "driver/rtc_io.h"

#include "heap.h"
#include "process.h"
#include "memory.h"
#include "messaging.h"
#include "embedded_data.h"
#include "os.h"
#include "program.h"
#include "flash_registry.h"
#include "scheduler.h"
#include "rtc_memory_esp32.h"
#include "vm.h"
#include "objects_inline.h"
#include "third_party/dartino/gc_metadata.h"

namespace toit {

const Program* setup_program(bool supports_ota) {
  if (supports_ota) {
#ifndef CONFIG_IDF_TARGET_ESP32C3
    const esp_partition_t* configured = esp_ota_get_boot_partition();
    const esp_partition_t* running = esp_ota_get_running_partition();

    if (configured != running) {
      ESP_LOGW("Toit", "Configured OTA boot partition at offset 0x%08" PRIx32 ", but running from offset 0x%08" PRIx32,
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

  const EmbeddedDataExtension* extension = EmbeddedData::extension();
  EmbeddedImage boot = extension->image(0);
  return boot.program;
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
    create_and_start_external_message_handlers(&vm);
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
  const esp_partition_t* running = esp_ota_get_running_partition();
  bool firmware_updated = !firmware_rejected && supports_ota &&
      esp_ota_get_boot_partition() != running;

  if (firmware_updated) {
    // If we're updating the firmware, we call esp_restart to ensure we fully
    // reset the chip with the new firmware.
    ets_printf("[toit] INFO: firmware updated; doing chip reset\n");
    RtcMemory::invalidate();   // Careful: This clears the RTC memory on boot.
    esp_restart();
  }

  switch (exit_state.reason) {
    case Scheduler::EXIT_DEEP_SLEEP: {
      const int64 MIN_MS = 50;
      const int64 MAX_MS = 1 * 24 * 60 * 60 * 1000;  // 1 day.
      int64 ms = exit_state.value;
      if (ms < MIN_MS) ms = MIN_MS;
      else if (ms > MAX_MS) ms = MAX_MS;
      ets_printf("[toit] INFO: entering deep sleep for %lldms\n", ms);
      err_t err = esp_sleep_enable_timer_wakeup(ms * 1000);
      if (err != ERR_OK) FATAL("cannot enable deep sleep timer");
      break;
    }

    case Scheduler::EXIT_ERROR: {
      esp_ota_img_states_t ota_state;
      esp_err_t err = esp_ota_get_state_partition(running, &ota_state);
      // If we are running from the factory partition esp_ota_get_state_partition()
      // fails. In that case, we're not rejecting a firmware update.
      if (err == ESP_OK && ota_state == ESP_OTA_IMG_PENDING_VERIFY) {
        ets_printf("[toit] WARN: firmware update rejected; doing chip reset\n");
        RtcMemory::invalidate();   // Careful: This clears the RTC memory on boot.
        esp_restart();
      }

      // Sleep for 1s before restarting after an error.
      ets_printf("[toit] WARN: entering deep sleep for 1s due to error\n");
      esp_sleep_enable_timer_wakeup(1000000);
      break;
    }

    case Scheduler::EXIT_DONE: {
      ets_printf("[toit] INFO: entering deep sleep without wakeup time\n");
      break;
    }

    case Scheduler::EXIT_NONE: {
      UNREACHABLE();
    }
  }

  // Work around https://github.com/espressif/esp-idf/issues/16192.
  // Some RTC pins have pull-ups and pull-downs enabled by default, which
  // aren't cleared after v5.1.1.
  // Clear them now.
  for (int i = 0; i < SOC_GPIO_PIN_COUNT; i++) {
    gpio_num_t pin = static_cast<gpio_num_t>(i);
    if (rtc_gpio_is_valid_gpio(pin)) {
      rtc_gpio_deinit(pin);
      rtc_gpio_pullup_dis(pin);
      rtc_gpio_pulldown_dis(pin);
    }
  }
  RtcMemory::on_deep_sleep_start();
  esp_deep_sleep_start();
}

} // namespace toit

extern "C" void toit_start() {
  toit::start();
}

#endif // TOIT_ESP32
