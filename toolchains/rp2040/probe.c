// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
// Native application used to validate remote updates before porting the VM.
#include <stdio.h>
#include <string.h>
#include "hardware/structs/watchdog.h"
#include "hardware/structs/io_bank0.h"
#include "hardware/structs/pads_bank0.h"
#include "hardware/sync.h"
#include "hardware/watchdog.h"
#include "pico/stdlib.h"
#include "pico/bootrom.h"
#include "pico/unique_id.h"
#include "update.h"
#include "tusb.h"

static volatile bool recovery_requested = false;

void tud_cdc_line_coding_cb(uint8_t interface, const cdc_line_coding_t* coding) {
  if (interface == 0 && coding->bit_rate == 1200) recovery_requested = true;
}



static bool test_pin(unsigned pin) {
#ifdef TOIT_PICO_W_2023
  if (pin == 0 || pin == 1) return false;  // Onboard ESP8285 UART.
#endif
  return pin <= 22 || (pin >= 26 && pin <= 28);
}

static void release_test_pins(void) {
  for (unsigned pin = 0; pin < 30; pin++) {
    if (!test_pin(pin)) continue;
    gpio_init(pin);
    gpio_set_dir(pin, GPIO_IN);
    gpio_disable_pulls(pin);
  }
}

int main(void) {
  watchdog_enable(8000, false);
  stdio_init_all();
  char id[2 * PICO_UNIQUE_BOARD_ID_SIZE_BYTES + 1];
  pico_get_unique_board_id_string(id, sizeof(id));
  char line[32];
  unsigned length = 0;
  uint64_t next = 0;
  for (;;) {
    watchdog_update();
    if (recovery_requested) {
      watchdog_hw->scratch[0] = UPDATE_REQUEST;
      watchdog_reboot(0, 0, 100);
      for (;;) tight_loop_contents();
    }
    if (time_us_64() >= next) {
      printf("RP2040-PROBE version=%u id=%s\n", TOIT_RP2040_PROBE_VERSION, id);
      next = time_us_64() + 1000000;
    }
    int value = getchar_timeout_us(1000);
    if (value < 0 || value == '\r') continue;
    if (value == '\n') {
      line[length] = 0;
      length = 0;
      if (!strcmp(line, "update")) {
        watchdog_hw->scratch[0] = UPDATE_REQUEST;
        watchdog_reboot(0, 0, 100);
        for (;;) tight_loop_contents();
      } else if (!strcmp(line, "bootsel")) {
        // Enter the ROM USB loader without driving any header GPIOs. This
        // does not write flash; loader replacement remains a separate action.
        reset_usb_boot(0, 0);
      } else if (!strcmp(line, "hang")) {
        // Exercise watchdog recovery with interrupts disabled as well.
        save_and_disable_interrupts();
        for (;;) tight_loop_contents();
      } else if (!strcmp(line, "pins")) {
        release_test_pins();
        puts("PINS READY inputs-only");
      } else {
        unsigned pin, pull;
        char extra;
        if (sscanf(line, "pull %u %u %c", &pin, &pull, &extra) == 2 &&
            test_pin(pin) && pull <= 2) {
          // No output driver is enabled. This also leaves the radio's pads
          // untouched. Pull 0 floats, 1 pulls up, and 2 pulls down.
          release_test_pins();
          gpio_set_pulls(pin, pull == 1, pull == 2);
          sleep_ms(10);
          printf("PULL %u %u %u\n", pin, pull, gpio_get(pin));
          printf("PAD %u ctrl=%08lx status=%08lx pad=%08lx in=%08lx oe=%08lx\n",
              pin, (unsigned long)io_bank0_hw->io[pin].ctrl,
              (unsigned long)io_bank0_hw->io[pin].status,
              (unsigned long)pads_bank0_hw->io[pin],
              (unsigned long)sio_hw->gpio_in, (unsigned long)sio_hw->gpio_oe);
        }
      }
    } else if (length < sizeof(line) - 1) {
      line[length++] = value;
    }
  }
}
