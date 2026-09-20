// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

// Native validation of the ROM A/B trial/confirmation mechanism. This is a
// bring-up instrument, not the Toit update transport or production boot path.
#include <stdio.h>
#include "pico/stdlib.h"
#include "pico/bootrom.h"
#include "hardware/watchdog.h"

static uint32_t buy_buffer[4096 / sizeof(uint32_t)];

int main(void) {
  stdio_init_all();
  sleep_ms(1500);
  boot_info_t info = {0};
  rom_get_boot_info(&info);
  printf("OTA probe version=%u partition=%d type=%u trial=%u\n",
      TOIT_OTA_PROBE_VERSION, info.partition, info.boot_type,
      info.tbyb_and_update_info);
  printf("Commands: c=confirm, r=reset, b=USB bootloader\n");
  absolute_time_t next = make_timeout_time_ms(1000);
  while (true) {
    int command = getchar_timeout_us(10000);
    if (command == 'c') {
      int result = rom_explicit_buy((uint8_t*)buy_buffer, sizeof(buy_buffer));
      printf("OTA confirm result=%d version=%u\n", result, TOIT_OTA_PROBE_VERSION);
    } else if (command == 'r') {
      watchdog_reboot(0, 0, 10);
    } else if (command == 'b') {
      reset_usb_boot(0, 0);
    }
    if (time_reached(next)) {
      printf("OTA alive version=%u partition=%d\n", TOIT_OTA_PROBE_VERSION, info.partition);
      next = make_timeout_time_ms(1000);
    }
  }
}
