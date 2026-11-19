// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the GNU Lesser General Public
// License, version 2.1, as found in the LICENSE file.

#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

#include "esp_mac.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/ringbuf.h"
#include "freertos/task.h"
#include "tinyusb.h"
#include "tinyusb_cdc_acm.h"
#include "tinyusb_default_config.h"

static char serial_number[sizeof("TOITS31000000000000")];
static const char* strings[] = {
  (const char[]) {0x09, 0x04},
  "Toit",
  "Toit ESP32-S31 USB Console",
  serial_number,
  "Console",
};

static _Atomic(RingbufHandle_t) log_buffer;
static TaskHandle_t console_task;

ssize_t __real__write_r(struct _reent* reent, int fd, const void* data, size_t size);

ssize_t __wrap__write_r(struct _reent* reent, int fd, const void* data, size_t size) {
  if (fd == STDOUT_FILENO || fd == STDERR_FILENO) {
    RingbufHandle_t buffer = atomic_load(&log_buffer);
    // UART0 remains the primary console. An absent or slow USB host must
    // never block the VM or the UART.
    if (buffer && size) xRingbufferSend(buffer, data, size, 0);
  }
  return __real__write_r(reent, fd, data, size);
}

static void line_coding_changed(int interface, cdcacm_event_t* event) {
  const cdc_line_coding_t* coding = event->line_coding_changed_data.p_line_coding;
  // Jaguar sends 1200 8E2. Ordinary 8N1 console opens never request a reboot.
  if (coding->bit_rate == 1200 && coding->data_bits == 8 &&
      coding->parity == 2 && coding->stop_bits == 2) {
    xTaskNotifyGive(console_task);
  }
}

static void run_console(void* arg) {
  RingbufHandle_t buffer = arg;
  for (;;) {
    if (ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(10))) {
      // Let the CDC control transfer complete before dropping the port.
      vTaskDelay(pdMS_TO_TICKS(100));
      tud_disconnect();
      vTaskDelay(pdMS_TO_TICKS(300));
      esp_restart();
    }
    if (!tud_cdc_connected() || tud_cdc_write_available() == 0) continue;
    size_t size;
    uint8_t* data = xRingbufferReceiveUpTo(buffer, &size, 0, tud_cdc_write_available());
    if (!data) continue;
    tud_cdc_write(data, size);
    tud_cdc_write_flush();
    vRingbufferReturnItem(buffer, data);
  }
}

void usb_console_start(void) {
  uint8_t mac[6];
  if (esp_efuse_mac_get_default(mac) != ESP_OK) return;
  snprintf(serial_number, sizeof(serial_number), "TOITS31%02X%02X%02X%02X%02X%02X",
           mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

  tinyusb_config_t usb = TINYUSB_DEFAULT_CONFIG();
  usb.descriptor.string = strings;
  usb.descriptor.string_count = sizeof(strings) / sizeof(strings[0]);
  if (tinyusb_driver_install(&usb) != ESP_OK) return;

  RingbufHandle_t buffer = xRingbufferCreate(8192, RINGBUF_TYPE_BYTEBUF);
  if (!buffer || xTaskCreate(run_console, "usb-console", 3072, buffer, 5, &console_task) != pdPASS) {
    if (buffer) vRingbufferDelete(buffer);
    tinyusb_driver_uninstall();
    return;
  }

  const tinyusb_config_cdcacm_t cdc = {
    .cdc_port = TINYUSB_CDC_ACM_0,
    .callback_line_coding_changed = line_coding_changed,
  };
  if (tinyusb_cdcacm_init(&cdc) != ESP_OK) {
    vTaskDelete(console_task);
    vRingbufferDelete(buffer);
    tinyusb_driver_uninstall();
    return;
  }
  atomic_store(&log_buffer, buffer);
}
