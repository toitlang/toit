// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include "driver/gpio.h"
#include "driver/uart.h"
#include "esp_chip_info.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#if CONFIG_IDF_TARGET_ESP32H2
static const int pins[] = {0, 1, 2, 3, 4, 5, 10};
#elif CONFIG_IDF_TARGET_ESP32
static const int pins[] = {12, 13, 14, 26, 27, 32, 33, 35};
#else
#error Unsupported fixture chip
#endif

static bool allowed(int pin) {
  for (unsigned i = 0; i < sizeof(pins) / sizeof(pins[0]); i++) {
    if (pins[i] == pin) return true;
  }
  return false;
}

static esp_err_t input(int pin, int pull) {
  gpio_config_t cfg = {
    .pin_bit_mask = 1ULL << pin,
    .mode = GPIO_MODE_INPUT,
    .pull_up_en = pull == 1,
    .pull_down_en = pull == 2,
    .intr_type = GPIO_INTR_DISABLE,
  };
  return gpio_config(&cfg);
}

static void release(void) {
  for (unsigned i = 0; i < sizeof(pins) / sizeof(pins[0]); i++) {
    ESP_ERROR_CHECK(input(pins[i], 0));
  }
#if CONFIG_IDF_TARGET_ESP32
  // Still connected to the H2 crystal/header net: never drive or pull this pin.
  ESP_ERROR_CHECK(input(25, 0));
#endif
}

static void command(char *line) {
  int pin, value;
  esp_err_t err = ESP_OK;
  if (!strcmp(line, "RESET")) {
    release();
  } else if (!strcmp(line, "INFO")) {
    uint8_t mac[6];
    esp_chip_info_t info;
    esp_chip_info(&info);
    ESP_ERROR_CHECK(esp_read_mac(mac, ESP_MAC_BASE));
    printf("RIG INFO %s rev=%d cores=%d mac=%02x:%02x:%02x:%02x:%02x:%02x\n",
           CONFIG_IDF_TARGET, info.revision, info.cores,
           mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    return;
  } else if (!strcmp(line, "READ")) {
    uint64_t levels = 0;
    for (unsigned i = 0; i < sizeof(pins) / sizeof(pins[0]); i++) {
      if (gpio_get_level(pins[i])) levels |= 1ULL << pins[i];
    }
    printf("RIG READ %" PRIx64 "\n", levels);
    return;
  } else if (sscanf(line, "INPUT %d %d", &pin, &value) == 2 && allowed(pin) && value >= 0 && value <= 2) {
    if (value && !GPIO_IS_VALID_OUTPUT_GPIO(pin)) err = ESP_ERR_INVALID_ARG;
    else err = input(pin, value);
  } else if ((sscanf(line, "OD %d %d", &pin, &value) == 2 ||
              sscanf(line, "DRIVE %d %d", &pin, &value) == 2) &&
             allowed(pin) && GPIO_IS_VALID_OUTPUT_GPIO(pin) && (value == 0 || value == 1)) {
    bool open_drain = line[0] == 'O';
    gpio_set_level(pin, value);
    gpio_config_t cfg = {
      .pin_bit_mask = 1ULL << pin,
      .mode = open_drain ? GPIO_MODE_INPUT_OUTPUT_OD : GPIO_MODE_INPUT_OUTPUT,
      .pull_up_en = open_drain,
      .intr_type = GPIO_INTR_DISABLE,
    };
    err = gpio_config(&cfg);
  } else {
    err = ESP_ERR_INVALID_ARG;
  }
  printf("RIG %s\n", err == ESP_OK ? "OK" : "ERROR");
}

void app_main(void) {
  release();
  ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0, 1024, 1024, 0, NULL, 0));
  setvbuf(stdout, NULL, _IONBF, 0);
  printf("RIG READY %s\n", CONFIG_IDF_TARGET);
  char line[80];
  unsigned used = 0;
  int64_t last_command = esp_timer_get_time();
  while (true) {
    uint8_t byte;
    if (uart_read_bytes(UART_NUM_0, &byte, 1, pdMS_TO_TICKS(100)) == 1) {
      if (byte == '\n') {
        line[used] = 0;
        command(line);
        used = 0;
        last_command = esp_timer_get_time();
      } else if (byte != '\r') {
        if (used < sizeof(line) - 1) line[used++] = byte;
        else used = 0;
      }
    }
    // Release outputs if the host disappears, including the helper's strap net.
    if (esp_timer_get_time() - last_command > 3000000) {
      release();
      last_command = esp_timer_get_time();
    }
  }
}
