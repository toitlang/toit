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
// Sourced from the luatos SDK's own GPIO example
// (project_legacy/example_gpio/src/example_main.c, allGpioMap) — the one
// place in the SDK that lists every GPIO with its pad AND mux. It agrees
// with every mapping we have HW-verified (pads 16, 22-26, 31-34) and
// supersedes the RTE_Device.h comment blocks, which ship two conflicting
// variants.
//
// All GPIOs mux at function 0 except GPIO12..15 (pads 11..14), which sit
// at function 4 — see pad_gpio_mux below. (Our earlier sweep drove pads
// 13/14 at function 0 and wrongly concluded they had no GPIO.)
static const int8_t kGpioPrimaryPad[32] = {
  /*  0 */ 15, /*  1 */ 16, /*  2 */ 17, /*  3 */ 18,
  /*  4 */ 19, /*  5 */ 20, /*  6 */ 21, /*  7 */ 22,
  /*  8 */ 23, /*  9 */ 24, /* 10 */ 25, /* 11 */ 26,
  /* 12 */ 11, /* 13 */ 12, /* 14 */ 13, /* 15 */ 14,
  /* 16 */ 31, /* 17 */ 32, /* 18 */ 33, /* 19 */ 34,
  // The AON-domain GPIOs (AGPIO): 20..28 on pads 40..48. They are powered
  // by the AON IO LDO, which is off until slpManAONIOPowerOn() — the GPIO
  // driver turns it on when one of these pads is opened. GPIO20
  // (AGPIOWU0) and friends double as wakeup pads in sleep modes.
  /* 20 */ 40, /* 21 */ 41, /* 22 */ 42, /* 23 */ 43,
  /* 24 */ 44, /* 25 */ 45, /* 26 */ 46, /* 27 */ 47,
  /* 28 */ 48, /* 29 */ 35, /* 30 */ 36, /* 31 */ 37,
};

// Alternate pad for the GPIOs that have one. The SDK's example table maps
// every GPIO to exactly one pad, so there are currently no alternates; the
// mechanism stays for the lib/ec618 API.
static const int8_t kGpioAltPad[32] = {
  /*  0 */ -1, /*  1 */ -1, /*  2 */ -1, /*  3 */ -1,
  /*  4 */ -1, /*  5 */ -1, /*  6 */ -1, /*  7 */ -1,
  /*  8 */ -1, /*  9 */ -1, /* 10 */ -1, /* 11 */ -1,
  /* 12 */ -1, /* 13 */ -1, /* 14 */ -1, /* 15 */ -1,
  /* 16 */ -1, /* 17 */ -1, /* 18 */ -1, /* 19 */ -1,
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

int pad_gpio_mux(int pad) {
  // GPIO12..15 (pads 11..14) sit at iomux function 4; every other GPIO
  // pad muxes its GPIO at function 0.
  return (pad >= 11 && pad <= 14) ? 4 : 0;
}

bool pad_is_aon(int pad) {
  return pad >= 40 && pad <= 48;
}

// --- UART pad table --------------------------------------------------------
//
// Each row pins down (controller, role, alternate-mapping) → (pad, mux).
// `mapping` is the user-visible alternate selector:
//   UART0 mapping=0: primary pads (pads 30/29 + 27/28 flow control)
//   UART0 mapping=1: alt pads     (GPIO16/17 muxed to UART0)
//   UART1 mapping=0: only mapping (GPIO18/19 + GPIO16/17 flow control)
//   UART1 CTS mapping=1: alt CTS pad (PAD22 / GPIO7)
//   UART2 mapping=0: primary pads (GPIO10/11)
//   UART2 mapping=1: alt 1        (pads 27/28 muxed to UART2 with mux=5)
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
  // UART0 — primary mapping (pads 30/29; no GPIO function on them).
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
  // UART1 CTS has a second pad (PAD22 / GPIO7); useful when GPIO17 isn't
  // broken out on the module.
  {1, UartRole::CTS, 1, 22, 1},

  // UART2 — primary mapping (GPIO10/11). No hardware flow control on UART2.
  {2, UartRole::TX,  0, 26, 3},
  {2, UartRole::RX,  0, 25, 3},
  // UART2 — alt 1 (pads 27/28 muxed with mux=5).
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
