// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>

#include "driver/gpio.h"
#include "driver/i2c_slave.h"
#include "esp_check.h"
#include "esp_intr_alloc.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "i2c_private.h"
#include "soc/i2c_struct.h"

#ifndef I2C_STALE_COUNT_TEST_ONLY
#error "This interrupt-suppression helper must only be built as a hardware test."
#endif

enum {
  I2C_PORT = 0,
  I2C_SLAVE_ADDRESS = 0x42,
  I2C_SDA_GPIO = 16,
  I2C_SCL_GPIO = 17,
  CONTROLLER_READY_GPIO = 13,
  TARGET_READY_GPIO = 27,
  TEST_LENGTH = 20,
  REPETITIONS = 3,
};

typedef struct {
  uint32_t length;
  uint32_t first_mismatch;
  bool driver_overflow;
  bool raw_overflow;
} receive_event_t;

typedef struct {
  QueueHandle_t queue;
} context_t;

static const char *TAG = "i2c-stale-count";

static uint8_t pattern_byte(uint32_t index) {
  return (uint8_t)((index * 31 + 23) & 0xff);
}

static bool receive_callback(
    i2c_slave_dev_handle_t slave,
    const i2c_slave_rx_done_event_data_t *event_data,
    void *user_data) {
  (void)slave;
  context_t *context = user_data;
  receive_event_t event = {
      .length = event_data->length,
      .first_mismatch = UINT32_MAX,
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

static void wait_for_level(gpio_num_t gpio, int level) {
  while (gpio_get_level(gpio) != level) vTaskDelay(1);
}

void app_main(void) {
  static context_t context;
  context.queue = xQueueCreate(1, sizeof(receive_event_t));
  ESP_ERROR_CHECK(context.queue == NULL ? ESP_ERR_NO_MEM : ESP_OK);

  const gpio_config_t handshake_inputs = {
      .pin_bit_mask = 1ULL << CONTROLLER_READY_GPIO,
      .mode = GPIO_MODE_INPUT,
      .pull_down_en = GPIO_PULLDOWN_ENABLE,
  };
  ESP_ERROR_CHECK(gpio_config(&handshake_inputs));
  ESP_ERROR_CHECK(gpio_set_direction(TARGET_READY_GPIO, GPIO_MODE_OUTPUT));
  ESP_ERROR_CHECK(gpio_set_level(TARGET_READY_GPIO, 0));

  const i2c_slave_config_t configuration = {
      .i2c_port = I2C_PORT,
      .sda_io_num = I2C_SDA_GPIO,
      .scl_io_num = I2C_SCL_GPIO,
      .clk_source = I2C_CLK_SRC_DEFAULT,
      .send_buf_depth = 64,
      .receive_buf_depth = 256,
      .slave_addr = I2C_SLAVE_ADDRESS,
      .addr_bit_len = I2C_ADDR_BIT_LEN_7,
      .flags.enable_internal_pullup = true,
  };
  i2c_slave_dev_handle_t slave;
  ESP_ERROR_CHECK(i2c_new_slave_device(&configuration, &slave));
  const i2c_slave_event_callbacks_t callbacks = {
      .on_receive = receive_callback,
  };
  ESP_ERROR_CHECK(i2c_slave_register_event_callbacks(slave, &callbacks, &context));

  ESP_LOGI(
      TAG,
      "ready: address=0x%02x SDA=GPIO%d SCL=GPIO%d test-length=%d",
      I2C_SLAVE_ADDRESS,
      I2C_SDA_GPIO,
      I2C_SCL_GPIO,
      TEST_LENGTH);

  for (int repetition = 0; repetition < REPETITIONS; repetition++) {
    wait_for_level(CONTROLLER_READY_GPIO, 1);
    I2C0.int_clr.rx_fifo_ovf = 1;
    ESP_ERROR_CHECK(esp_intr_disable(slave->base->intr_handle));
    ESP_ERROR_CHECK(gpio_set_level(TARGET_READY_GPIO, 1));
    wait_for_level(CONTROLLER_READY_GPIO, 0);
    ESP_ERROR_CHECK(gpio_set_level(TARGET_READY_GPIO, 0));

    uint32_t raw_before_enable = I2C0.int_raw.val;
    uint32_t fifo_before_enable = I2C0.status_reg.rx_fifo_cnt;
    ESP_ERROR_CHECK(esp_intr_enable(slave->base->intr_handle));

    receive_event_t event;
    if (xQueueReceive(context.queue, &event, pdMS_TO_TICKS(1000)) != pdTRUE) {
      ESP_LOGE(
          TAG,
          "RESULT repetition=%d raw=0x%08" PRIx32
          " fifo=%" PRIu32 " callback=timeout",
          repetition,
          raw_before_enable,
          fifo_before_enable);
      continue;
    }
    int32_t mismatch = event.first_mismatch == UINT32_MAX
        ? -1
        : (int32_t)event.first_mismatch;
    ESP_LOGI(
        TAG,
        "RESULT repetition=%d raw=0x%08" PRIx32
        " fifo=%" PRIu32 " length=%" PRIu32
        " mismatch=%" PRId32 " driver-overflow=%d raw-overflow=%d",
        repetition,
        raw_before_enable,
        fifo_before_enable,
        event.length,
        mismatch,
        event.driver_overflow,
        event.raw_overflow);
  }

  ESP_LOGI(TAG, "COMPLETE");
  ESP_ERROR_CHECK(gpio_set_direction(TARGET_READY_GPIO, GPIO_MODE_INPUT));
}
