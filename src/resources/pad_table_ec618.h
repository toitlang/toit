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
#include "../mutex.h"

namespace toit {

// Source-of-truth iomux table for the EC618.
//
// The chip has ~50 pads. Each pad has up to ~6 alt-functions (mux 0..5).
// Mux 0 maps the pad to a GPIO controller bit for those pads that have
// one; the GPIO controller bit can be shared between multiple pads (e.g.
// GPIO12 lives at PAD27 and PAD11), in which case the PAD number addresses
// a *physical pin* and the GPIO bit is what reads/writes do at the
// controller register.
//
// Toit-side pin addressing is by PAD number. GPIO numbers (which match
// what Air780 silkscreens print) are resolved exclusively by the `ec618`
// Toit library; native code always receives a PAD.
//
// GPIO data comes from the official CSDK's complete `allGpioMap` example
// table and its GPIO_ToPadEC618 helper. Peripheral routes come from the
// CSDK RTE_Device.h tables and luat_uart_ec618.c. Air780E board-contact
// aliases are a separate board-level concern documented by the hardware rig.

// Highest pad index we know about. Pads outside [1..kMaxPadIndex] or pads
// that aren't listed in the table are rejected at the primitive boundary.
static const int kMaxPadIndex = 48;

// Returns the GPIO controller bit number (0..31) for the pad, or -1 if
// the pad has no GPIO function.
int pad_to_gpio(int pad);

// The iomux function that selects GPIO on this pad (0 for most pads,
// 4 for the alternate pads 11..14 / GPIO12..15 and 38..39 / GPIO18..19).
int pad_gpio_mux(int pad);

// Whether the pad is an AON-domain GPIO (AGPIO, pads 40..48 / GPIO20..28).
// These are powered by the AON IO LDO (slpManAONIOPowerOn).
bool pad_is_aon(int pad);

// Acquires/releases a reference to the AON IO LDO. The first user powers
// the rail and selects 3.3 V; the last release powers it off.
void pad_aon_power_acquire();
void pad_aon_power_release();

// Whether another physical PAD maps to the same GPIO controller bit.
bool pad_gpio_is_shared(int pad);

// Reserves a physical PAD for a native peripheral. EC618 peripheral
// primitives receive PAD numbers directly and own the reservation until the
// resource is closed.
bool pad_pool_take(int pad);

// Resets a PAD to its disconnected state and returns its reservation.
void pad_pool_put(int pad);

// Returns PAD reservations for every set bit. PAD indices are 1..48 and fit
// in a single mask.
static inline void pad_pool_put_mask(uint64_t mask) {
  for (int pad = 0; mask != 0; pad++, mask >>= 1) {
    if (mask & 1) pad_pool_put(pad);
  }
}

// Accumulates PAD reservations while a peripheral is being constructed. Any
// reservation made before an error is returned automatically unless keep is
// called after ownership has been transferred to the resource.
class PadReserver {
 public:
  ~PadReserver() { pad_pool_put_mask(owned_); }

  bool take(int pad) {
    if (pad < 0) return true;
    ASSERT(0 < pad && pad <= kMaxPadIndex);
    if (!pad_pool_take(pad)) return false;
    owned_ |= uint64_t(1) << pad;
    return true;
  }

  void keep() { owned_ = 0; }
  uint64_t mask() const { return owned_; }

 private:
  uint64_t owned_ = 0;
};

// Holds the PADs owned by a native resource and releases them on close.
class Pads {
 public:
  ~Pads() { release(); }

  void adopt(const PadReserver& reserver) { mask_ = reserver.mask(); }

  void release() {
    pad_pool_put_mask(mask_);
    mask_ = 0;
  }

 private:
  uint64_t mask_ = 0;
};

// Holds the global pad/GPIO ownership lock while a peripheral temporarily
// accesses one or two pads through their GPIO controller bits. `available`
// is true only when every requested bit is currently unowned; a competing
// GPIO claim waits for this object's lifetime instead of observing a
// transient lease.
class PadGpioLock {
 public:
  PadGpioLock(int first_pad, int second_pad = -1);

  bool available() const { return available_; }

 private:
  Locker locker_;
  bool available_;
};

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
// the wire, input buffer off, pulls off. A pad whose controller bit is shared
// is muxed away from GPIO so later use of its sibling cannot also drive it.
// Peripheral-only pads keep their mux; an idle peripheral doesn't drive, so
// dropping the pulls releases them.
//
// Native resources normally use pad_pool_put, which performs this reset while
// returning the reservation. Drivers call pad_reset directly only to undo
// incidental SDK muxing of a PAD they do not own. The contract is "a closed
// pad is high-Z": a container can never leave a wire driven. (Implemented in
// gpio_ec618.cc, which has the SDK GPIO includes.)
void pad_reset(int pad);

// Emergency marker: mux the pad to GPIO and drive it HIGH, from any
// context (fatal paths). Used as a scope trigger when diagnosing
// resets — see the watchdog task. (Implemented in gpio_ec618.cc.)
void pad_emergency_high(int pad);

}  // namespace toit

#endif  // TOIT_EC618
