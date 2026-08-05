// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#pragma once

#include "../top.h"

#if defined(TOIT_ESP32) && defined(CONFIG_ESP_CONSOLE_UART)

#include "driver/uart.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

namespace toit {

esp_err_t console_uart_acquire(int rx_buffer_size, int tx_buffer_size, QueueHandle_t* queue);
void console_uart_release();

}  // namespace toit

#endif  // defined(TOIT_ESP32) && defined(CONFIG_ESP_CONSOLE_UART)
