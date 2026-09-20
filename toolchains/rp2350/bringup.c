// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.

// Native validation firmware. This does not run the Toit VM yet.
#include <stdio.h>

#include "hardware/uart.h"
#include "pico/stdlib.h"
#include "pico/unique_id.h"
#include "pico/version.h"

int main(void) {
  stdio_init_all();
  gpio_init(PICO_DEFAULT_LED_PIN);
  gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);

  // Keep the harness UART separate from USB stdout: binary echo, 115200 8N1.
  uart_init(uart0, 115200);
  gpio_set_function(TOIT_RP2350_UART_TX_PIN, GPIO_FUNC_UART);
  gpio_set_function(TOIT_RP2350_UART_RX_PIN, GPIO_FUNC_UART);
  uart_set_hw_flow(uart0, false, false);
  uart_set_format(uart0, 8, 1, UART_PARITY_NONE);

  char id[2 * PICO_UNIQUE_BOARD_ID_SIZE_BYTES + 1];
  pico_get_unique_board_id_string(id, sizeof(id));
  uint32_t tick = 0;
  uint32_t echoed = 0;
  uint64_t next_heartbeat = 0;
  while (true) {
    // Bound work per iteration so a continuous UART stream cannot starve USB.
    for (unsigned i = 0; i < 32 && uart_is_readable(uart0); i++) {
      uart_putc_raw(uart0, uart_getc(uart0));
      echoed++;
    }
    uint64_t now = time_us_64();
    if (now >= next_heartbeat) {
      gpio_put(PICO_DEFAULT_LED_PIN, tick & 1);
      printf("Toit RP2350 bring-up: board=%s id=%s sdk=%s tick=%lu uart_echo=%lu\n",
             PICO_BOARD, id, PICO_SDK_VERSION_STRING,
             (unsigned long)tick++, (unsigned long)echoed);
      next_heartbeat = now + 1000000;
    }
    tight_loop_contents();
  }
}
