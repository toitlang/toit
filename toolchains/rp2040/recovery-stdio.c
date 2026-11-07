// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "recovery-stdio.h"

#include <stdarg.h>
#include <stdio.h>
#ifdef TOIT_RECOVERY_STDIO_HOST_TEST
#include "recovery-stdio-stubs.h"
#else
#include "hardware/watchdog.h"
#include "pico/stdio.h"
#include "pico/stdio_usb.h"
#include "pico/time.h"
#include "tusb.h"
#endif

bool recovery_reply(const char* format, ...) {
  char message[128];
  va_list arguments;
  va_start(arguments, format);
  int length = vsnprintf(message, sizeof(message), format, arguments);
  va_end(arguments);
  if (length < 0 || (size_t)length >= sizeof(message)) return false;

  uint64_t deadline = time_us_64() + 5000000;
  for (int at = 0; at < length;) {
    if (!stdio_usb_connected() || time_us_64() >= deadline) return false;
    watchdog_update();
    uint32_t available = tud_cdc_write_available();
    if (available == 0) {
      sleep_us(1000);
      continue;
    }
    unsigned count = (unsigned)(length - at);
    if (count > available) count = available;
    // Main is the sole writer, on one core without an RTOS. The background
    // USB IRQ can only free TX space, so this chunk cannot hit stdio's lossy
    // full-FIFO timeout. Keep the SDK's USB mutex and disable CRLF expansion,
    // which could otherwise write more bytes than the reserved space.
    stdio_put_string(message + at, (int)count, false, false);
    at += (int)count;
  }
  return stdio_usb_connected();
}
