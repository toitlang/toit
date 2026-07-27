// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdbool.h>
#include <inttypes.h>
#include <stdint.h>
#include <string.h>

#include "driver/i2c_slave.h"
#include "driver/gpio.h"
#include "driver/pcnt.h"
#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "soc/gpio_struct.h"
#include "soc/pcnt_struct.h"

enum {
  I2C_PORT = 0,
  I2C_SLAVE_ADDRESS = 0x42,
  I2C_SDA_GPIO = 18,
  I2C_SCL_GPIO = 17,
  LONG_TRANSFER_LENGTH = 1025,
  STATUS_LENGTH = 8,
  CAPTURE_STATUS_LENGTH = 5,
  EVENT_QUEUE_LENGTH = 16,
};

enum {
  COMMAND_READ_PATTERN = 0xa1,
  COMMAND_WRITE_PATTERN = 0xa2,
  COMMAND_READ_STATUS = 0xa3,
  COMMAND_READ_CAPTURE = 0xa4,
  COMMAND_USE_PREPARED_RESPONSE = 0xaf,
};

typedef struct {
  uint8_t command;
  bool overflow;
  uint32_t length;
  uint32_t error_count;
  uint32_t first_error;
} event_t;

typedef enum {
  RESPONSE_STATUS,
  RESPONSE_PATTERN,
  RESPONSE_CAPTURE,
} response_type_t;

typedef struct {
  QueueHandle_t event_queue;
  i2c_slave_dev_handle_t slave;
  response_type_t response;
  uint8_t read_pattern[LONG_TRANSFER_LENGTH];
  uint8_t status[STATUS_LENGTH];
  uint8_t capture_status[CAPTURE_STATUS_LENGTH];
  volatile bool capture_armed;
  volatile bool capture_done;
  volatile uint8_t capture_starts;
  volatile uint8_t capture_stops;
} context_t;

static const char *TAG = "ec618-i2c-slave";

static uint8_t read_pattern_byte(uint32_t index) {
  return (uint8_t)((index * 31 + 7) & 0xff);
}

static uint8_t write_pattern_byte(uint32_t index) {
  return (uint8_t)((index * 17 + 3) & 0xff);
}

static void IRAM_ATTR sda_edge_handler(void *user_data) {
  context_t *context = user_data;
  uint32_t levels = GPIO.in;
  if (!context->capture_armed ||
      !(levels & (1u << I2C_SCL_GPIO))) return;

  if (levels & (1u << I2C_SDA_GPIO)) {
    context->capture_starts = PCNT.cnt_unit[PCNT_UNIT_0].cnt_val;
    // This ISR is the rising SDA edge while SCL is high: the STOP itself.
    // PCNT can commit that same edge after the ISR has begun, so record the
    // observed STOP directly instead of racing its counter update.
    context->capture_stops = 1;
    context->capture_armed = false;
    context->capture_done = true;
  }
}

static void configure_capture_counter(
    pcnt_unit_t unit,
    pcnt_count_mode_t positive,
    pcnt_count_mode_t negative) {
  const pcnt_config_t configuration = {
      .pulse_gpio_num = I2C_SDA_GPIO,
      .ctrl_gpio_num = I2C_SCL_GPIO,
      .lctrl_mode = PCNT_MODE_DISABLE,
      .hctrl_mode = PCNT_MODE_KEEP,
      .pos_mode = positive,
      .neg_mode = negative,
      .counter_h_lim = INT16_MAX,
      .counter_l_lim = 0,
      .unit = unit,
      .channel = PCNT_CHANNEL_0,
  };
  ESP_ERROR_CHECK(pcnt_unit_config(&configuration));
  ESP_ERROR_CHECK(pcnt_counter_pause(unit));
  ESP_ERROR_CHECK(pcnt_counter_clear(unit));
}

static void arm_capture(context_t *context) {
  ESP_ERROR_CHECK(pcnt_counter_pause(PCNT_UNIT_0));
  ESP_ERROR_CHECK(pcnt_counter_clear(PCNT_UNIT_0));
  context->capture_starts = 0;
  context->capture_stops = 0;
  context->capture_done = false;
  context->capture_armed = true;
  ESP_ERROR_CHECK(pcnt_counter_resume(PCNT_UNIT_0));
}

static bool receive_callback(
    i2c_slave_dev_handle_t slave,
    const i2c_slave_rx_done_event_data_t *event_data,
    void *user_data) {
  (void)slave;
  context_t *context = user_data;
  event_t event = {
      .command = event_data->length == 0 ? 0 : event_data->buffer[0],
      .length = event_data->length,
      .first_error = UINT32_MAX,
  };

  if (event.command == COMMAND_WRITE_PATTERN) {
    for (uint32_t i = 1; i < event_data->length; i++) {
      if (event_data->buffer[i] != write_pattern_byte(i)) {
        if (event.first_error == UINT32_MAX) event.first_error = i;
        event.error_count++;
      }
    }
  }

  BaseType_t task_woken = pdFALSE;
  xQueueSendFromISR(context->event_queue, &event, &task_woken);
  return task_woken == pdTRUE;
}

static void prepare_status(context_t *context, const event_t *event) {
  bool ok = !event->overflow &&
      event->length == LONG_TRANSFER_LENGTH &&
      event->error_count == 0;
  uint32_t first_error =
      event->first_error == UINT32_MAX ? 0xffff : event->first_error;

  context->status[0] = 'S';
  context->status[1] = 'T';
  context->status[2] = ok;
  context->status[3] = event->overflow;
  context->status[4] = event->length & 0xff;
  context->status[5] = (event->length >> 8) & 0xff;
  context->status[6] = first_error & 0xff;
  context->status[7] = (first_error >> 8) & 0xff;
}

static void send_response(context_t *context) {
  const uint8_t *data;
  uint32_t length;
  if (context->response == RESPONSE_PATTERN) {
    data = context->read_pattern;
    length = sizeof(context->read_pattern);
  } else if (context->response == RESPONSE_CAPTURE) {
    data = context->capture_status;
    length = sizeof(context->capture_status);
  } else {
    data = context->status;
    length = sizeof(context->status);
  }

  uint32_t total_written = 0;
  while (total_written < length) {
    uint32_t written = 0;
    esp_err_t result = i2c_slave_write(
        context->slave,
        data + total_written,
        length - total_written,
        &written,
        1000);
    if (result != ESP_OK || written == 0) {
      ESP_LOGE(
          TAG,
          "response failed after %" PRIu32 "/%" PRIu32 " bytes: %s",
          total_written,
          length,
          esp_err_to_name(result));
      return;
    }
    total_written += written;
  }
}

static void slave_task(void *user_data) {
  context_t *context = user_data;
  event_t event;

  while (true) {
    if (xQueueReceive(context->event_queue, &event, portMAX_DELAY) != pdTRUE) {
      continue;
    }

    switch (event.command) {
      case COMMAND_READ_PATTERN:
        context->response = RESPONSE_PATTERN;
        send_response(context);
        // This task runs after the command's STOP, so the next transaction's
        // first high-SCL SDA edge is its START rather than the arming STOP.
        arm_capture(context);
        ESP_LOGI(TAG, "long-pattern response selected");
        break;
      case COMMAND_READ_STATUS:
        context->response = RESPONSE_STATUS;
        send_response(context);
        break;
      case COMMAND_WRITE_PATTERN:
        prepare_status(context, &event);
        send_response(context);
        ESP_LOGI(
            TAG,
            "write length=%" PRIu32 ", errors=%" PRIu32 ", overflow=%d",
            event.length,
            event.error_count,
            event.overflow);
        break;
      case COMMAND_READ_CAPTURE:
        context->capture_status[0] = 'C';
        context->capture_status[1] = 'P';
        context->capture_status[2] = context->capture_done;
        context->capture_status[3] = context->capture_starts;
        context->capture_status[4] = context->capture_stops;
        context->response = RESPONSE_CAPTURE;
        send_response(context);
        ESP_LOGI(
            TAG,
            "capture done=%d starts=%u stops=%u",
            context->capture_done,
            context->capture_starts,
            context->capture_stops);
        break;
      case COMMAND_USE_PREPARED_RESPONSE:
        // Deliberately leave the already queued response untouched. Calling
        // i2c_slave_write while the ESP32 is transmitting that response can
        // overwrite bytes still owned by the peripheral.
        break;
      default:
        ESP_LOGW(
            TAG,
            "unknown command 0x%02x in %" PRIu32 "-byte write",
            event.command,
            event.length);
        break;
    }
  }
}

void app_main(void) {
  static context_t context = {
      .response = RESPONSE_STATUS,
      .status = {'S', 'T', 0, 0, 0, 0, 0xff, 0xff},
  };

  for (uint32_t i = 0; i < LONG_TRANSFER_LENGTH; i++) {
    context.read_pattern[i] = read_pattern_byte(i);
  }

  context.event_queue = xQueueCreate(EVENT_QUEUE_LENGTH, sizeof(event_t));
  ESP_ERROR_CHECK(context.event_queue == NULL ? ESP_ERR_NO_MEM : ESP_OK);

  const i2c_slave_config_t configuration = {
      .i2c_port = I2C_PORT,
      .sda_io_num = I2C_SDA_GPIO,
      .scl_io_num = I2C_SCL_GPIO,
      .clk_source = I2C_CLK_SRC_DEFAULT,
      .send_buf_depth = 2048,
      .receive_buf_depth = 2048,
      .slave_addr = I2C_SLAVE_ADDRESS,
      .addr_bit_len = I2C_ADDR_BIT_LEN_7,
      .flags.enable_internal_pullup = true,
  };
  configure_capture_counter(
      PCNT_UNIT_0, PCNT_COUNT_DIS, PCNT_COUNT_INC);
  ESP_ERROR_CHECK(i2c_new_slave_device(&configuration, &context.slave));

  const i2c_slave_event_callbacks_t callbacks = {
      .on_receive = receive_callback,
  };
  ESP_ERROR_CHECK(
      i2c_slave_register_event_callbacks(context.slave, &callbacks, &context));

  ESP_ERROR_CHECK(gpio_install_isr_service(ESP_INTR_FLAG_IRAM));
  ESP_ERROR_CHECK(
      gpio_set_intr_type(I2C_SDA_GPIO, GPIO_INTR_ANYEDGE));
  ESP_ERROR_CHECK(
      gpio_isr_handler_add(I2C_SDA_GPIO, sda_edge_handler, &context));

  BaseType_t task_created = xTaskCreate(
      slave_task,
      "i2c-slave",
      4096,
      &context,
      10,
      NULL);
  ESP_ERROR_CHECK(task_created == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);

  ESP_LOGI(
      TAG,
      "ready: address=0x%02x, SDA=GPIO%d, SCL=GPIO%d",
      I2C_SLAVE_ADDRESS,
      I2C_SDA_GPIO,
      I2C_SCL_GPIO);
}
