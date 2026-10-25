// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include <cmath>
#include <stdint.h>

namespace toit {
// Nordic PWM uses a 16 MHz clock divided by 1..128 and a 3..32767 counter.
// Select the finest resolution whose period does not exceed the counter.
struct ZephyrPwmPeriod {
  static constexpr uint32_t CLOCK_HZ = 16000000;
  static constexpr int MIN_FREQUENCY = 4;
  static constexpr int MAX_FREQUENCY = CLOCK_HZ / 3;
  uint32_t cycles = 0;
  uint32_t scale = 1;

  bool set(int frequency) {
    if (frequency < MIN_FREQUENCY || frequency > MAX_FREQUENCY) return false;
    uint32_t requested = (CLOCK_HZ + frequency / 2) / frequency;
    uint32_t divider = 1;
    while ((requested + divider / 2) / divider > 32767) divider *= 2;
    cycles = ((requested + divider / 2) / divider) * divider;
    scale = divider;
    return true;
  }

  uint32_t pulse(double factor) const {
    // Callers reject NaN. Clamp infinities as well as finite out-of-range values.
    if (factor <= 0) return 0;
    if (factor >= 1) return cycles;
    return static_cast<uint32_t>(factor * (cycles / scale) + 0.5) * scale;
  }
  int frequency() const { return CLOCK_HZ / cycles; }
};
}  // namespace toit
