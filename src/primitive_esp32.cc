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
#include "heap.h"
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

#ifdef __riscv
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

PRIMITIVE(reset_reason) {
  return Smi::from(esp_reset_reason());
}

PRIMITIVE(total_deep_sleep_time) {
  return Primitive::integer(RtcMemory::total_deep_sleep_time(), process);
}

PRIMITIVE(enable_external_wakeup) {
#ifndef __riscv
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
#ifndef __riscv
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

} // namespace toit

#endif // TOIT_FREERTOS
