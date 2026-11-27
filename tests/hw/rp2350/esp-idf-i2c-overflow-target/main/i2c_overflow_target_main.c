// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "driver/i2c_slave.h"
#include "driver/uart.h"
#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "soc/i2c_reg.h"
#include "soc/i2c_struct.h"

#ifndef I2C_OVERFLOW_TARGET_TEST_ONLY
#error "This raw-register diagnostic must only be built as a hardware test."
#endif

enum {
  I2C_PORT = 0,
  I2C_SLAVE_ADDRESS = 0x42,
  I2C_RECEIVE_DEPTH = 4096,
  CONTROL_UART = UART_NUM_1,
  CONTROL_TX_GPIO = 4,
  CONTROL_RX_GPIO = 34,
  CONTROL_BAUD = 115200,
  CONTROL_BUFFER_SIZE = 256,
};

typedef struct {
  uint32_t length;
  uint32_t first_mismatch;
  uint32_t raw_status;
  uint32_t interrupt_enable;
  uint32_t fifo_count;
  bool driver_overflow;
  bool raw_overflow;
} receive_event_t;

typedef struct {
  QueueHandle_t queue;
} context_t;

static const char *TAG = "i2c-overflow";

static uint8_t pattern_byte(uint32_t index) {
  return (uint8_t)((index * 31 + 23) & 0xff);
}

static bool receive_callback(i2c_slave_dev_handle_t slave,
                             const i2c_slave_rx_done_event_data_t *event_data,
                             void *user_data) {
  (void)slave;
  context_t *context = user_data;
  receive_event_t event = {
      .length = event_data->length,
      .first_mismatch = UINT32_MAX,
      .raw_status = I2C0.int_raw.val,
      .interrupt_enable = I2C0.int_ena.val,
      .fifo_count = I2C0.status_reg.rx_fifo_cnt,
      .driver_overflow = event_data->overflow,
      .raw_overflow = I2C0.int_raw.rx_fifo_ovf,
  };
  for (uint32_t i = 0; i < event_data->length; i++) {
    if (event_data->buffer[i] != pattern_byte(i)) {
      event.first_mismatch = i;
      break;
    }
  }
  BaseType_t task_woken = pdFALSE;
  xQueueSendFromISR(context->queue, &event, &task_woken);
  return task_woken == pdTRUE;
}

static void send_line(const char *format, ...) {
  char buffer[CONTROL_BUFFER_SIZE];
  va_list arguments;
  va_start(arguments, format);
  int length = vsnprintf(buffer, sizeof(buffer) - 2, format, arguments);
  va_end(arguments);
  if (length < 0)
    return;
  if (length > (int)sizeof(buffer) - 2)
    length = sizeof(buffer) - 2;
  buffer[length++] = '\n';
  uart_write_bytes(CONTROL_UART, buffer, length);
  uart_wait_tx_done(CONTROL_UART, pdMS_TO_TICKS(1000));
}

static bool read_line(char *buffer, size_t capacity) {
  size_t length = 0;
  while (true) {
    uint8_t byte;
    int count = uart_read_bytes(CONTROL_UART, &byte, 1, portMAX_DELAY);
    if (count != 1)
      continue;
    if (byte == '\r')
      continue;
    if (byte == '\n') {
      buffer[length] = '\0';
      return true;
    }
    if (length + 1 < capacity) {
      buffer[length++] = (char)byte;
    } else {
      buffer[0] = '\0';
      return false;
    }
  }
}

static bool controller_pins(int controller, gpio_num_t *sda, gpio_num_t *scl) {
  if (controller == 0) {
    *sda = GPIO_NUM_19;
    *scl = GPIO_NUM_27;
    return true;
  }
  if (controller == 1) {
    *sda = GPIO_NUM_32;
    *scl = GPIO_NUM_33;
    return true;
  }
  return false;
}

static esp_err_t create_target(int controller, context_t *context,
                               i2c_slave_dev_handle_t *target) {
  gpio_num_t sda;
  gpio_num_t scl;
  ESP_RETURN_ON_FALSE(controller_pins(controller, &sda, &scl),
                      ESP_ERR_INVALID_ARG, TAG, "invalid controller");
  const i2c_slave_config_t configuration = {
      .i2c_port = I2C_PORT,
      .sda_io_num = sda,
      .scl_io_num = scl,
      .clk_source = I2C_CLK_SRC_DEFAULT,
      .send_buf_depth = 64,
      .receive_buf_depth = I2C_RECEIVE_DEPTH,
      .slave_addr = I2C_SLAVE_ADDRESS,
      .addr_bit_len = I2C_ADDR_BIT_LEN_7,
      .flags.enable_internal_pullup = true,
  };
  ESP_RETURN_ON_ERROR(i2c_new_slave_device(&configuration, target), TAG,
                      "create target");
  const i2c_slave_event_callbacks_t callbacks = {
      .on_receive = receive_callback,
  };
  esp_err_t result =
      i2c_slave_register_event_callbacks(*target, &callbacks, context);
  if (result != ESP_OK) {
    i2c_del_slave_device(*target);
    *target = NULL;
    return result;
  }
  I2C0.int_clr.val = I2C_RXFIFO_OVF_INT_CLR_M;
  return ESP_OK;
}

void app_main(void) {
  const uart_config_t uart_configuration = {
      .baud_rate = CONTROL_BAUD,
      .data_bits = UART_DATA_8_BITS,
      .parity = UART_PARITY_DISABLE,
      .stop_bits = UART_STOP_BITS_1,
      .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
      .source_clk = UART_SCLK_DEFAULT,
  };
  ESP_ERROR_CHECK(uart_driver_install(CONTROL_UART, CONTROL_BUFFER_SIZE,
                                      CONTROL_BUFFER_SIZE, 0, NULL, 0));
  ESP_ERROR_CHECK(uart_param_config(CONTROL_UART, &uart_configuration));
  ESP_ERROR_CHECK(uart_set_pin(CONTROL_UART, CONTROL_TX_GPIO, CONTROL_RX_GPIO,
                               UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));

  context_t context = {
      .queue = xQueueCreate(4, sizeof(receive_event_t)),
  };
  ESP_ERROR_CHECK(context.queue == NULL ? ESP_ERR_NO_MEM : ESP_OK);
  i2c_slave_dev_handle_t target = NULL;

  ESP_LOGI(TAG, "ready: UART%d TX=GPIO%d RX=GPIO%d address=0x%02x",
           CONTROL_UART, CONTROL_TX_GPIO, CONTROL_RX_GPIO, I2C_SLAVE_ADDRESS);

  char command[128];
  while (true) {
    if (!read_line(command, sizeof(command))) {
      send_line("ERROR command-too-long");
      continue;
    }
    ESP_LOGI(TAG, "control: '%s'", command);
    if (strcmp(command, "SYNC") == 0) {
      send_line("READY");
      continue;
    }
    int controller;
    int expected_size;
    if (sscanf(command, "ARM %d %d", &controller, &expected_size) == 2) {
      if (target != NULL) {
        ESP_ERROR_CHECK(i2c_del_slave_device(target));
        target = NULL;
      }
      xQueueReset(context.queue);
      esp_err_t result = create_target(controller, &context, &target);
      if (result != ESP_OK) {
        send_line("ERROR arm=%s", esp_err_to_name(result));
        continue;
      }
      send_line("READY");
      continue;
    }
    if (sscanf(command, "STATUS %d", &expected_size) == 1) {
      receive_event_t event;
      if (xQueueReceive(context.queue, &event, pdMS_TO_TICKS(2000)) != pdTRUE) {
        send_line(
            "expected=%d callback=timeout raw-overflow=%d raw=0x%08" PRIx32
            " ena=0x%08" PRIx32 " fifo=%" PRIu32,
            expected_size, I2C0.int_raw.rx_fifo_ovf, I2C0.int_raw.val,
            I2C0.int_ena.val, I2C0.status_reg.rx_fifo_cnt);
        continue;
      }
      int32_t mismatch = event.first_mismatch == UINT32_MAX
                             ? -1
                             : (int32_t)event.first_mismatch;
      send_line("expected=%d received=%" PRIu32 " mismatch=%" PRId32
                " driver-overflow=%d raw-overflow=%d raw=0x%08" PRIx32
                " ena=0x%08" PRIx32 " fifo=%" PRIu32
                " now-raw-overflow=%d now-raw=0x%08" PRIx32
                " now-ena=0x%08" PRIx32 " now-fifo=%" PRIu32,
                expected_size, event.length, mismatch, event.driver_overflow,
                event.raw_overflow, event.raw_status, event.interrupt_enable,
                event.fifo_count, I2C0.int_raw.rx_fifo_ovf, I2C0.int_raw.val,
                I2C0.int_ena.val, I2C0.status_reg.rx_fifo_cnt);
      continue;
    }
    if (strcmp(command, "CLOSE") == 0) {
      if (target != NULL) {
        ESP_ERROR_CHECK(i2c_del_slave_device(target));
        target = NULL;
      }
      send_line("OK");
      continue;
    }
    if (strcmp(command, "QUIT") == 0) {
      if (target != NULL) {
        ESP_ERROR_CHECK(i2c_del_slave_device(target));
        target = NULL;
      }
      send_line("BYE");
      break;
    }
    send_line("ERROR invalid-command");
  }

  vQueueDelete(context.queue);
  uart_driver_delete(CONTROL_UART);
  ESP_LOGI(TAG, "complete; I2C and control UART pins released");
}
