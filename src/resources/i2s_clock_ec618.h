// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in the LICENSE file.

#pragma once

#include <stdint.h>

namespace toit {

// Both outputs share a Q8.24 fractional divider from the 409.6 MHz root.
// The vendor selector is named FRACDIC_ROOT_CLK_408M, but its RF calibration
// reference and measured integer-divided I2S clocks establish 409.6 MHz.
// OUT0 feeds MCLK; OUT1 and a further integer divider feed stereo BCLK.
// Keep this arithmetic independent of the register writes for host testing.
struct I2sClockPlan {
  uint32_t integer;
  uint32_t fraction;
  uint8_t output_divider;
  uint8_t bit_clock_divider;

  // EC618 Datasheet V1.3, section 7.5: 16/24-bit I2S reaches 96 kHz,
  // while 32-bit I2S is specified only through 48 kHz.
  static int maximum_sample_rate(int bits) { return bits == 32 ? 48000 : 96000; }

  static bool calculate(int rate, int bits, int multiplier, I2sClockPlan* result) {
    if (rate <= 0 || rate > maximum_sample_rate(bits) ||
        (bits != 8 && bits != 16 && bits != 24 && bits != 32)) return false;
    switch (multiplier) {
      case 128: case 256: case 384: case 512:
      case 576: case 768: case 1024: case 1152: break;
      default: return false;
    }
    if (multiplier % (2 * bits) != 0) return false;
    const uint64_t unit = uint64_t(1) << 24;
    const uint64_t numerator = uint64_t(409600000) * unit;
    // Prefer the vendor's divide-by-four route. Other post-dividers extend
    // the rate range without overflowing the eight-bit integer divider.
    const unsigned dividers[] = {4, 2, 1, 8, 16, 32, 64, 128};
    for (unsigned divider : dividers) {
      uint64_t denominator = uint64_t(rate) * multiplier * divider;
      uint64_t ratio = (numerator + denominator / 2) / denominator;
      if (ratio < unit || ratio > 256 * unit) continue;
      result->integer = ratio >> 24;
      result->fraction = ratio & (unit - 1);
      result->output_divider = divider;
      result->bit_clock_divider = multiplier / (2 * bits);
      return true;
    }
    return false;
  }
};

}  // namespace toit
