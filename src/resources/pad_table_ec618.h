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

#pragma once

#ifdef TOIT_EC618

#include "../top.h"

namespace toit {

// Source-of-truth iomux table for the EC618.
//
// The chip has ~50 pads. Each pad has up to ~6 alt-functions (mux 0..5).
// Mux 0 maps the pad to a GPIO controller bit for those pads that have
// one; the GPIO controller bit can be shared between multiple pads (e.g.
// GPIO11 lives at both PAD22 and PAD26), in which case the pad addresses
// a *physical pin* and the GPIO bit is what reads/writes do at the
// controller register.
//
// Toit-side pin addressing is by PAD number; GPIO numbers (which match
// what Air780 silkscreens print) are exposed via the `ec618` Toit library
// and resolved to pads through the helpers below.
//
// Data extracted from RTE_Device.h comments and luat_uart_ec618.c.

// Highest pad index we know about. Pads outside [1..kMaxPadIndex] or pads
// that aren't listed in the table are rejected at the primitive boundary.
static const int kMaxPadIndex = 47;

// Returns the GPIO controller bit number (0..31) for a pad's mux=0
// position, or -1 if the pad isn't a GPIO bit.
int pad_to_gpio(int pad);

// Returns the primary pad for the given GPIO number (`alt=0`) or its
// alternate pad if one exists (`alt=1`). Returns -1 if the GPIO has
// no entry / no such alternate.
int gpio_to_pad(int gpio_num, int alt);

// UART function lookup. `mapping` selects between alternate routings:
//   UART0:  0 = primary (TX=PAD30 RX=PAD29), 1 = alt (TX=PAD24 RX=PAD23)
//   UART1:  0 = only mapping (TX=PAD34 RX=PAD33)
//   UART2:  0 = primary (TX=PAD26 RX=PAD25), 1 = alt1 (TX=PAD28 RX=PAD27),
//                                            2 = alt2 (TX/RX on PADs of
//                                            GPIO7/GPIO6 — TBD per chip docs)
//
// Returns the pad index, or -1 if no such mapping exists. *out_mux gets
// the iomux selector to write into the pad's PCR.
enum class UartRole : uint8_t {
  TX,
  RX,
  RTS,
  CTS,
};

int uart_pad(int uart_id, UartRole role, int mapping, int* out_mux);

// Returns a pad to a defined, disconnected state: interrupt off, GPIO
// controller bit (if the pad has one) released to input so nothing drives
// the wire, iomux back to plain GPIO with the input buffer off, pulls off.
// Peripheral-only pads keep their mux (function 0 is undefined for them);
// an idle peripheral doesn't drive, so dropping the pulls releases them.
//
// Every driver that muxed a pad calls this when the owning resource goes
// away — INCLUDING the forced teardown of a killed container. The contract
// is "a closed pad is high-Z": a container can never leave a wire driven.
// (Implemented in gpio_ec618.cc, which has the SDK GPIO includes.)
void pad_release(int pad);

}  // namespace toit

#endif  // TOIT_EC618
