// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
// Native UART diagnostics for the W-2023 onboard ESP8285, without VM events.
#include <stdio.h>
#include <string.h>
#include "hardware/uart.h"
#include "pico/stdlib.h"
#include "pico/stdio_usb.h"
#include "pico/stdio/driver.h"

static bool active;
static uint64_t deadline;
static unsigned received;
static bool bridge;
static unsigned tx_pin;
static unsigned rx_pin;

static void stop(void) {
  if (!active) return;
  uart_deinit(uart0);
  gpio_init(tx_pin);
  gpio_init(rx_pin);
  gpio_disable_pulls(tx_pin);
  gpio_disable_pulls(rx_pin);
  active = false;
  bridge = false;
}

bool modem_probe_bridge_active(void) { return active && bridge; }

bool modem_probe_command(const char* command) {
  unsigned baud;
  char extra;
  bool version = false;
  bool rom = false;
  bool new_bridge = false;
  bool external = false;
  if (sscanf(command, "modem %u %c", &baud, &extra) != 1) {
    if (sscanf(command, "modem-gmr %u %c", &baud, &extra) == 1) {
      version = true;
    } else if (sscanf(command, "modem-rom %u %c", &baud, &extra) == 1) {
      rom = true;
    } else if (sscanf(command, "modem-bridge %u %c", &baud, &extra) == 1) {
      new_bridge = true;
    } else if (sscanf(command, "uart-bridge %u %c", &baud, &extra) == 1) {
      new_bridge = true;
      external = true;
    } else {
      return false;
    }
  }
  if (baud < 1200 || baud > 1000000) return false;
  stop();
  tx_pin = external ? 16 : 0;
  rx_pin = external ? 17 : 1;
  // Route RX before enabling the receiver. An unmapped RX reads low and
  // can inject a spurious break/NUL at startup.
  gpio_set_function(rx_pin, GPIO_FUNC_UART);
  gpio_disable_pulls(tx_pin);
  gpio_disable_pulls(rx_pin);
  unsigned actual = uart_init(uart0, baud);
  uart_set_format(uart0, 8, 1, UART_PARITY_NONE);
  uart_set_hw_flow(uart0, false, false);
  gpio_set_function(tx_pin, GPIO_FUNC_UART);
  received = 0;
  active = true;
  bridge = new_bridge;
  if (bridge) {
    // Let pin-mux transitions and any peer echo settle before acknowledging
    // a new binary session. No bridge request has been accepted yet.
    sleep_ms(50);
    while (uart_is_readable(uart0)) (void)uart_get_hw(uart0)->dr;
    deadline = time_us_64() + 15000000;
    printf("BRIDGE READY baud=%u tx=%u rx=%u idle-timeout=15s\n", actual, tx_pin, rx_pin);
    stdio_flush();
    return true;
  }
  deadline = time_us_64() + 2000000;
  printf("MODEM baud=%u actual=%u command=%s\n", baud, actual,
         rom ? "ROM-SYNC" : version ? "AT+GMR" : "AT");
  if (rom) {
    // ESP ROM SYNC, SLIP framed. This only requests synchronization: it
    // neither loads code nor erases/writes flash or changes boot settings.
    const uint8_t header[] = {0xc0, 0, 8, 36, 0, 0, 0, 0, 0, 7, 7, 0x12, 0x20};
    uart_write_blocking(uart0, header, sizeof(header));
    for (unsigned i = 0; i < 32; i++) uart_putc_raw(uart0, 0x55);
    uart_putc_raw(uart0, 0xc0);
  } else {
    uart_puts(uart0, version ? "AT+GMR\r\n" : "AT\r\n");
  }
  return true;
}

void modem_probe_poll(void) {
  if (!active) return;
  if (bridge) {
    // Bounded polling, no CR/LF translation and no diagnostic output mixed
    // into the binary stream. Main continues feeding the watchdog.
    char buffer[64];
    unsigned length = 0;
    while (uart_is_readable(uart0) && length < sizeof(buffer)) {
      buffer[length++] = uart_get_hw(uart0)->dr & 0xff;
    }
    if (length) {
      stdio_usb.out_chars(buffer, length);
      deadline = time_us_64() + 15000000;
    }
    for (unsigned i = 0; i < 64 && uart_is_writable(uart0); i++) {
      int value = getchar_timeout_us(0);
      if (value < 0) break;
      uart_get_hw(uart0)->dr = value;
      deadline = time_us_64() + 15000000;
    }
    if (time_us_64() >= deadline) {
      stop();
      puts("BRIDGE DONE");
    }
    return;
  }
  unsigned count = 0;
  while (uart_is_readable(uart0) && count++ < 64) {
    // Keep framing/break/overrun flags, which uart_getc would discard.
    unsigned data = uart_get_hw(uart0)->dr;
    printf("MODEM RX %02x errors=%x\n", data & 0xff, (data >> 8) & 0xf);
    received++;
  }
  if (time_us_64() >= deadline) {
    printf("MODEM DONE bytes=%u\n", received);
    stop();
  }
}
