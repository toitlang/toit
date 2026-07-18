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

// --- PAD -> GPIO-controller mapping ---------------------------------------
//
// Sourced from the SDK's GPIO_ToPadEC618 implementation. Its alt-function
// selector matters: GPIO12..15 and GPIO18..19 each have two physical pads.
// This agrees with the SDK GPIO example, which deliberately selects the ALT4
// pads for GPIO12..15.
//
// All primary GPIO pads mux at function 0. The alternate pads 11..14 and
// 38..39 use function 4 — see pad_gpio_mux below. (Our earlier sweep drove
// pads 13/14 at function 0 and wrongly concluded they had no GPIO.)
//
// This table deliberately runs in the public direction: PAD in, controller
// bit out. Logical GPIO -> PAD selection belongs in lib/ec618/ec618.toit.
static const int8_t kPadToGpio[kMaxPadIndex + 1] = {
  /*  0 */ -1,
  /*  1 */ -1, /*  2 */ -1, /*  3 */ -1, /*  4 */ -1, /*  5 */ -1,
  /*  6 */ -1, /*  7 */ -1, /*  8 */ -1, /*  9 */ -1, /* 10 */ -1,
  /* 11 */ 12, /* 12 */ 13, /* 13 */ 14, /* 14 */ 15,
  /* 15 */  0, /* 16 */  1, /* 17 */  2, /* 18 */  3,
  /* 19 */  4, /* 20 */  5, /* 21 */  6, /* 22 */  7,
  /* 23 */  8, /* 24 */  9, /* 25 */ 10, /* 26 */ 11,
  /* 27 */ 12, /* 28 */ 13, /* 29 */ 14, /* 30 */ 15,
  /* 31 */ 16, /* 32 */ 17, /* 33 */ 18, /* 34 */ 19,
  /* 35 */ 29, /* 36 */ 30, /* 37 */ 31, /* 38 */ 18, /* 39 */ 19,
  // The AON-domain GPIOs on pads 40..48 are powered by the AON IO LDO.
  /* 40 */ 20, /* 41 */ 21, /* 42 */ 22, /* 43 */ 23, /* 44 */ 24,
  /* 45 */ 25, /* 46 */ 26, /* 47 */ 27, /* 48 */ 28,
};

int pad_to_gpio(int pad) {
  if (pad < 0 || pad > kMaxPadIndex) return -1;
  return kPadToGpio[pad];
}

bool pad_gpio_is_shared(int pad) {
  int gpio_bit = pad_to_gpio(pad);
  if (gpio_bit < 0) return false;
  for (int sibling = 1; sibling <= kMaxPadIndex; sibling++) {
    if (sibling != pad && pad_to_gpio(sibling) == gpio_bit) return true;
  }
  return false;
}

int pad_gpio_mux(int pad) {
  // The alternate pads sit at iomux function 4; primary pads use function 0.
  return ((pad >= 11 && pad <= 14) || (pad >= 38 && pad <= 39)) ? 4 : 0;
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
