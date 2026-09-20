// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.

// Native endpoint for the RP2350/ESP32 electrical harness test.
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hardware/adc.h"
#include "hardware/gpio.h"
#include "hardware/uart.h"
#include "pico/platform.h"
#include "pico/stdlib.h"
#include "pico/unique_id.h"
#include "pico/version.h"

#ifndef TOIT_RP2350_UART_TX_PIN
#define TOIT_RP2350_UART_TX_PIN 16
#endif

#ifndef TOIT_RP2350_UART_RX_PIN
#define TOIT_RP2350_UART_RX_PIN 1
#endif

#define CONTROL_UART uart0
#define CONTROL_BAUD 115200
#define MAX_LINE 96
#define MAX_ECHO 8192

static const uint8_t kDigitalPins[] = {4, 5, 6, 7, 8, 9, 10, 11, 32, 33};
static bool control_connected;

static bool is_digital_test_pin(unsigned pin) {
  for (unsigned i = 0; i < sizeof(kDigitalPins); i++) {
    if (kDigitalPins[i] == pin) return true;
  }
  return false;
}

static void release_pin(unsigned pin) {
  gpio_init(pin);
  gpio_set_dir(pin, GPIO_IN);
  gpio_disable_pulls(pin);
}

static void release_test_pins(void) {
  for (unsigned i = 0; i < sizeof(kDigitalPins); i++) {
    release_pin(kDigitalPins[i]);
  }
  adc_gpio_init(40);
  adc_gpio_init(41);
}

static void reply(const char *message) {
  uart_puts(CONTROL_UART, message);
  uart_putc_raw(CONTROL_UART, '\n');
}

static bool parse_uint(const char *text, unsigned *result) {
  if (text == NULL || *text == '\0') return false;
  char *end = NULL;
  unsigned long value = strtoul(text, &end, 10);
  if (*end != '\0' || value > UINT32_MAX) return false;
  *result = (unsigned)value;
  return true;
}

static void handle_command(char *line) {
  char *save = NULL;
  char *command = strtok_r(line, " ", &save);
  if (command == NULL) return;

  if (strcmp(command, "HELLO") == 0) {
    char *token = strtok_r(NULL, " ", &save);
    if (token == NULL || strtok_r(NULL, " ", &save) != NULL) {
      reply("ERR HELLO");
      return;
    }
    char response[MAX_LINE];
    snprintf(response, sizeof(response), "READY %s REV %u", token,
             rp2350_chip_version());
    control_connected = true;
    reply(response);
    return;
  }

  if (strcmp(command, "RELEASE") == 0) {
    release_test_pins();
    reply("OK RELEASE");
    return;
  }

  char *pin_text = strtok_r(NULL, " ", &save);
  unsigned pin;
  if (!parse_uint(pin_text, &pin)) {
    reply("ERR PIN");
    return;
  }

  if (strcmp(command, "OUT") == 0) {
    char *value_text = strtok_r(NULL, " ", &save);
    unsigned value;
    if (!is_digital_test_pin(pin) || !parse_uint(value_text, &value) ||
        value > 1 || strtok_r(NULL, " ", &save) != NULL) {
      reply("ERR OUT");
      return;
    }
    gpio_init(pin);
    gpio_disable_pulls(pin);
    gpio_put(pin, value);
    gpio_set_dir(pin, GPIO_OUT);
    char response[MAX_LINE];
    snprintf(response, sizeof(response), "OK OUT %u %u", pin, value);
    reply(response);
    return;
  }

  if (strcmp(command, "IN") == 0) {
    if (!is_digital_test_pin(pin) || strtok_r(NULL, " ", &save) != NULL) {
      reply("ERR IN");
      return;
    }
    release_pin(pin);
    char response[MAX_LINE];
    snprintf(response, sizeof(response), "OK IN %u", pin);
    reply(response);
    return;
  }

  if (strcmp(command, "READ") == 0) {
    if (!is_digital_test_pin(pin) || strtok_r(NULL, " ", &save) != NULL) {
      reply("ERR READ");
      return;
    }
    char response[MAX_LINE];
    snprintf(response, sizeof(response), "VALUE %u %u", pin, gpio_get(pin));
    reply(response);
    return;
  }

  if (strcmp(command, "PULL") == 0) {
    char *mode = strtok_r(NULL, " ", &save);
    if (!is_digital_test_pin(pin) || mode == NULL || mode[1] != '\0' ||
        strtok_r(NULL, " ", &save) != NULL) {
      reply("ERR PULL");
      return;
    }
    release_pin(pin);
    if (mode[0] == 'U') {
      gpio_pull_up(pin);
    } else if (mode[0] == 'D') {
      gpio_pull_down(pin);
    } else if (mode[0] != 'N') {
      reply("ERR PULL");
      return;
    }
    sleep_ms(20);
    char response[MAX_LINE];
    snprintf(response, sizeof(response), "PULL %u %c %u", pin, mode[0],
             gpio_get(pin));
    reply(response);
    return;
  }

  if (strcmp(command, "ADC") == 0) {
    char *samples_text = strtok_r(NULL, " ", &save);
    unsigned samples;
    if ((pin != 40 && pin != 41) || !parse_uint(samples_text, &samples) ||
        samples == 0 || samples > 1024 ||
        strtok_r(NULL, " ", &save) != NULL) {
      reply("ERR ADC");
      return;
    }
    adc_gpio_init(pin);
    adc_select_input(pin - 40);
    // Flush the sample-and-hold after changing channels, especially on the
    // 10 kohm source used by GP41.
    for (unsigned i = 0; i < 16; i++) {
      (void)adc_read();
      sleep_us(20);
    }
    uint32_t sum = 0;
    uint16_t minimum = UINT16_MAX;
    uint16_t maximum = 0;
    for (unsigned i = 0; i < samples; i++) {
      uint16_t sample = adc_read();
      sum += sample;
      if (sample < minimum) minimum = sample;
      if (sample > maximum) maximum = sample;
      sleep_us(20);
    }
    char response[MAX_LINE];
    snprintf(response, sizeof(response), "ADC %u %lu %u %u", pin,
             (unsigned long)(sum / samples), minimum, maximum);
    reply(response);
    return;
  }

  if (strcmp(command, "ECHO") == 0) {
    unsigned count = pin;
    if (count == 0 || count > MAX_ECHO ||
        strtok_r(NULL, " ", &save) != NULL) {
      reply("ERR ECHO");
      return;
    }
    char response[MAX_LINE];
    snprintf(response, sizeof(response), "ECHO %u", count);
    reply(response);
    for (unsigned i = 0; i < count; i++) {
      uart_putc_raw(CONTROL_UART, uart_getc(CONTROL_UART));
    }
    return;
  }

  reply("ERR COMMAND");
}

int main(void) {
  stdio_init_all();
  gpio_init(PICO_DEFAULT_LED_PIN);
  gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
  adc_init();
  release_test_pins();

  uart_init(CONTROL_UART, CONTROL_BAUD);
  gpio_set_function(TOIT_RP2350_UART_TX_PIN, GPIO_FUNC_UART);
  gpio_set_function(TOIT_RP2350_UART_RX_PIN, GPIO_FUNC_UART);
  uart_set_hw_flow(CONTROL_UART, false, false);
  uart_set_format(CONTROL_UART, 8, 1, UART_PARITY_NONE);

  char id[2 * PICO_UNIQUE_BOARD_ID_SIZE_BYTES + 1];
  pico_get_unique_board_id_string(id, sizeof(id));
  printf("RP2350 rig test: board=%s id=%s sdk=%s revision=%u\n", PICO_BOARD,
         id, PICO_SDK_VERSION_STRING, rp2350_chip_version());

  char line[MAX_LINE];
  unsigned length = 0;
  bool overflow = false;
  uint64_t next_banner = 0;
  uint32_t blink = 0;
  while (true) {
    if (uart_is_readable(CONTROL_UART)) {
      int c = uart_getc(CONTROL_UART);
      if (c == '\r') continue;
      if (c == '\n') {
        if (overflow) {
          reply("ERR LINE");
        } else if (length != 0) {
          line[length] = '\0';
          handle_command(line);
        }
        length = 0;
        overflow = false;
      } else if (!overflow) {
        if (length + 1 < sizeof(line)) {
          line[length++] = (char)c;
        } else {
          overflow = true;
        }
      }
    }

    uint64_t now = time_us_64();
    if (!control_connected && now >= next_banner) {
      char banner[MAX_LINE];
      snprintf(banner, sizeof(banner), "RIG RP2350 REV %u",
               rp2350_chip_version());
      reply(banner);
      gpio_put(PICO_DEFAULT_LED_PIN, blink++ & 1);
      next_banner = now + 1000000;
    }
    tight_loop_contents();
  }
}
