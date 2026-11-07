// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include <stdbool.h>
#include <stdint.h>

uint64_t time_us_64(void);
void sleep_us(uint64_t delay);
void watchdog_update(void);
bool stdio_usb_connected(void);
uint32_t tud_cdc_write_available(void);
int stdio_put_string(const char* bytes, int length, bool newline, bool cr_translation);
