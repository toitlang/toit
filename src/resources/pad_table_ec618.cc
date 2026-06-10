// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "../top.h"

#ifdef TOIT_EC618

#include "pad_table_ec618.h"

namespace toit {

// --- GPIO <-> PAD mapping --------------------------------------------------
//
// Primary pad for each GPIO controller bit (0..31). -1 means we don't have a
// mapping documented for that GPIO yet; users targeting it will get an
// INVALID_ARGUMENT and we'll add the entry once we can confirm against the
// chip datasheet.
//
// Sourced from RTE_Device.h pad-comment annotations; the SDK's
// GPIO_ToPadEC618(gpio, 0) returns the same pad at runtime.
static const int8_t kGpioPrimaryPad[32] = {
  /*  0 */ -1, /*  1 */ -1, /*  2 */ 13, /*  3 */ 14,
  /*  4 */ 15, /*  5 */ 16, /*  6 */ -1, /*  7 */ -1,
  /*  8 */ 23, /*  9 */ 24, /* 10 */ 25, /* 11 */ 26,
  /* 12 */ 27, /* 13 */ 28, /* 14 */ 29, /* 15 */ 30,
  /* 16 */ 31, /* 17 */ 32, /* 18 */ 33, /* 19 */ 34,
  // The AON-domain GPIOs: 20..27 on pads 40..47 (pad = gpio + 20; pads
  // 43/44/45/47 corroborated by the SDK's PWM map), 28..30 on pads
  // 37/35/36. GPIO20..22 double as wakeup pads and may not drive as
  // plain GPIO.
  /* 20 */ 40, /* 21 */ 41, /* 22 */ 42, /* 23 */ 43,
  /* 24 */ 44, /* 25 */ 45, /* 26 */ 46, /* 27 */ 47,
  /* 28 */ 37, /* 29 */ 35, /* 30 */ 36, /* 31 */ -1,
};

// Alternate pad for the GPIOs that have one. -1 means the GPIO has no
// alternate routing.
//
// Beware: the SDK's RTE_Device.h comment blocks ship TWO conflicting
// pad-function tables (e.g. one claims pads 23/24 are GPIO14/15 + UART1
// RX/TX). HW-verified on the Air780E: pads 23/24 are GPIO8/9 and UART1 is
// on pads 33/34, i.e. the other variant is the one that matches.
static const int8_t kGpioAltPad[32] = {
  /*  0 */ -1, /*  1 */ -1, /*  2 */ 17, /*  3 */ 18,
  /*  4 */ 19, /*  5 */ 20, /*  6 */ -1, /*  7 */ -1,
  /*  8 */ -1, /*  9 */ -1, /* 10 */ -1, /* 11 */ 22,
  /* 12 */ -1, /* 13 */ -1, /* 14 */ -1, /* 15 */ -1,
  /* 16 */ 21, /* 17 */ -1, /* 18 */ 38, /* 19 */ 39,
  /* 20 */ -1, /* 21 */ -1, /* 22 */ -1, /* 23 */ -1,
  /* 24 */ -1, /* 25 */ -1, /* 26 */ -1, /* 27 */ -1,
  /* 28 */ -1, /* 29 */ -1, /* 30 */ -1, /* 31 */ -1,
};

int gpio_to_pad(int gpio_num, int alt) {
  if (gpio_num < 0 || gpio_num >= 32) return -1;
  if (alt == 0) return kGpioPrimaryPad[gpio_num];
  if (alt == 1) return kGpioAltPad[gpio_num];
  return -1;
}

int pad_to_gpio(int pad) {
  if (pad < 0 || pad > kMaxPadIndex) return -1;
  // Linear scan; the table is small and lookups happen at construction
  // time, not on the hot path.
  for (int gpio = 0; gpio < 32; gpio++) {
    if (kGpioPrimaryPad[gpio] == pad) return gpio;
    if (kGpioAltPad[gpio] == pad) return gpio;
  }
  return -1;
}

// --- UART pad table --------------------------------------------------------
//
// Each row pins down (controller, role, alternate-mapping) → (pad, mux).
// `mapping` is the user-visible alternate selector:
//   UART0 mapping=0: primary pads (GPIO14/15 + GPIO12/13 flow control)
//   UART0 mapping=1: alt pads     (GPIO16/17 muxed to UART0)
//   UART1 mapping=0: only mapping (GPIO18/19 + GPIO16/17 flow control)
//   UART1 CTS mapping=1: alt CTS pad (PAD22 / GPIO11 alt pad)
//   UART2 mapping=0: primary pads (GPIO10/11)
//   UART2 mapping=1: alt 1        (GPIO12/13 muxed to UART2 with mux=5)
//
// The mux values are extracted from luat_uart_ec618.c (UART2 alt 1 uses
// mux=5; everything else uses each chip's standard mux for that role).

struct UartPad {
  uint8_t uart_id;
  UartRole role;
  uint8_t mapping;
  uint8_t pad;
  uint8_t mux;
};

static const UartPad kUartPads[] = {
  // UART0 — primary mapping (GPIO14/15).
  {0, UartRole::TX,  0, 30, 3},
  {0, UartRole::RX,  0, 29, 3},
  {0, UartRole::RTS, 0, 27, 3},
  {0, UartRole::CTS, 0, 28, 3},
  // UART0 — alternate mapping (GPIO16/17 muxed to UART0). Flow control is
  // not exposed on this mapping; if you need flow control, use mapping=0.
  {0, UartRole::TX,  1, 32, 3},
  {0, UartRole::RX,  1, 31, 3},

  // UART1 — only mapping (GPIO18/19 + GPIO16/17 flow control).
  {1, UartRole::TX,  0, 34, 1},
  {1, UartRole::RX,  0, 33, 1},
  {1, UartRole::RTS, 0, 31, 1},
  {1, UartRole::CTS, 0, 32, 1},
  // UART1 CTS has a second pad (GPIO11 alt pad); useful when GPIO17 isn't
  // broken out on the module.
  {1, UartRole::CTS, 1, 22, 1},

  // UART2 — primary mapping (GPIO10/11). No hardware flow control on UART2.
  {2, UartRole::TX,  0, 26, 3},
  {2, UartRole::RX,  0, 25, 3},
  // UART2 — alt 1 (GPIO12/13 muxed with mux=5).
  {2, UartRole::TX,  1, 28, 5},
  {2, UartRole::RX,  1, 27, 5},
  // UART2 alt 2 (GPIO6/7) is not yet listed — needs PAD numbers confirmed
  // against the chip datasheet before we expose it.
};

int uart_pad(int uart_id, UartRole role, int mapping, int* out_mux) {
  for (size_t i = 0; i < sizeof(kUartPads) / sizeof(kUartPads[0]); i++) {
    const UartPad& row = kUartPads[i];
    if (row.uart_id == uart_id && row.role == role && row.mapping == mapping) {
      if (out_mux != nullptr) *out_mux = row.mux;
      return row.pad;
    }
  }
  if (out_mux != nullptr) *out_mux = -1;
  return -1;
}

}  // namespace toit

#endif  // TOIT_EC618
