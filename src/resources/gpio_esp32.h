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

#include "../top.h"

#ifdef TOIT_ESP32

namespace toit {

// Shared access to the GPIO pin pool (defined in gpio_esp32.cc).
//
// Peripherals (RMT, I2C, SPI, ...) take a raw GPIO number and reserve/release
// the pin from this pool themselves.
//
// Pins are encoded as a single signed integer (see lib/gpio/gpio.toit
// `to-pin-num_`):
//   * -1       : no pin.
//   * num >= 0 : the peripheral reserves the pin and releases it when it is
//                closed.
//   * num <= -2: old API (deprecated). The Toit-side `gpio.Pin` owns the reservation;
//                the GPIO number is `-num - 2` and must not be reserved here.

// Reserves the GPIO pin `num` in the shared pin pool.
// Returns false if the pin is already in use.
bool gpio_pool_take(int num);

// Resets the configuration of `num` and returns it to the shared pin pool.
void gpio_pool_put(int num);

// Decodes an encoded pin value.
// Returns the GPIO number, or -1 for "no pin".
// Sets `*owned` to true when the caller must reserve the pin and release it
// again when done (encoded >= 0); false for a deprecated `gpio.Pin`.
static inline int gpio_decode_pin(int encoded, bool* owned) {
  if (encoded >= 0) {
    *owned = true;
    return encoded;
  }
  *owned = false;
  if (encoded == -1) return -1;
  return -encoded - 2;
}

// Returns pin numbers back to the shared pool for every set bit in `mask`.
static inline void gpio_pool_put_mask(uint64_t mask) {
  for (int num = 0; mask != 0; num++, mask >>= 1) {
    if (mask & 1) gpio_pool_put(num);
  }
}

// Reserves a set of GPIO pins for a single peripheral transactionally.
//
// Decode each encoded pin with `decode_and_take`. If any reservation fails the
// destructor releases everything taken so far, unless `keep()` was called. On
// success, copy the owned pins into the peripheral's resource (see `GpioPins`)
// and call `keep()`.
//
// The reserved pins are tracked as a bit-mask (bit N == GPIO N). GPIO numbers
// stay well below 64 on all supported chips, so a single `uint64_t` suffices.
class GpioPinReserver {
 public:
  ~GpioPinReserver() { gpio_pool_put_mask(owned_); }

  // Decodes `encoded` and, when the peripheral owns the pin (>= 0), reserves it.
  // On a failed reservation sets `*ok` to false and returns -1. Otherwise
  // returns the decoded GPIO number (or -1 for "no pin").
  // When `owned_out` is given, it is set to true iff the pin was reserved here,
  // so the caller can apply any extra pin configuration.
  int decode_and_take(int encoded, bool* ok, bool* owned_out = null) {
    bool owned;
    int num = gpio_decode_pin(encoded, &owned);
    if (owned_out) *owned_out = owned;
    if (owned) {
      ASSERT(0 <= num && num < 64);
      if (!gpio_pool_take(num)) {
        *ok = false;
        return -1;
      }
      owned_ |= uint64_t(1) << num;
    }
    return num;
  }

  // Transfers ownership of the reserved pins out of the reserver so the
  // destructor no longer releases them. Call after the pins have been copied
  // into the resource with `GpioPins::adopt`/`append`.
  void keep() { owned_ = 0; }

  // Whether at least one pin was reserved here.
  bool any() const { return owned_ != 0; }

  // The set of reserved pins as a bit-mask (bit N == GPIO N).
  uint64_t mask() const { return owned_; }

 private:
  uint64_t owned_ = 0;
};

// Holds the GPIO pins owned by a peripheral resource so they can be released
// when the resource is destroyed. Store one of these in the resource and call
// `adopt` after a successful reservation.
class GpioPins {
 public:
  void adopt(const GpioPinReserver& reserver) { mask_ = reserver.mask(); }

  // Like `adopt`, but adds to the already-owned pins instead of replacing them.
  // Used by peripherals that reserve pins across several primitive calls (e.g.
  // a pulse-counter unit that adds channels one at a time).
  void append(const GpioPinReserver& reserver) { mask_ |= reserver.mask(); }

  // Releases all owned pins back into the pool. Safe to call more than once.
  void release() {
    gpio_pool_put_mask(mask_);
    mask_ = 0;
  }

 private:
  uint64_t mask_ = 0;
};

} // namespace toit

#endif // TOIT_ESP32
