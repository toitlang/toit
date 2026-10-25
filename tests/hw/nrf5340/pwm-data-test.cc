// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include "../../../src/resources/pwm_zephyr_data.h"
#include <assert.h>
#include <initializer_list>
#include <limits.h>
#include <stdio.h>
using namespace toit;

int main() {
  ZephyrPwmPeriod period;
  for (int frequency = 4; frequency <= ZephyrPwmPeriod::MAX_FREQUENCY; ++frequency) {
    assert(period.set(frequency));
    assert(period.scale >= 1 && period.scale <= 128);
    assert((period.scale & (period.scale - 1)) == 0);
    assert(period.cycles % period.scale == 0);
    assert(period.cycles / period.scale >= 3 && period.cycles / period.scale <= 32767);
    // The chosen period is within one prescaled tick of the ideal period.
    double ideal = static_cast<double>(period.CLOCK_HZ) / frequency;
    assert(std::abs(period.cycles - ideal) <= period.scale);
    assert(period.pulse(-1) == 0);
    assert(period.pulse(2) == period.cycles);
    assert(period.pulse(0.5) <= period.cycles);
    assert(period.pulse(0.5) % period.scale == 0);
  }
  for (int frequency : {4, 50, 1000, 1000000, 5333333}) {
    assert(period.set(frequency));
    uint32_t previous = 0;
    for (int step = 0; step <= 10000; ++step) {
      double factor = step / 10000.0;
      uint32_t pulse = period.pulse(factor);
      assert(pulse >= previous && pulse <= period.cycles);
      assert(std::abs(pulse - factor * period.cycles) <= period.scale / 2.0 + 1e-8);
      previous = pulse;
    }
  }
  assert(period.set(50));
  assert(period.cycles == 320000 && period.scale == 16 && period.frequency() == 50);
  assert(period.pulse(INFINITY) == period.cycles);
  assert(period.pulse(-INFINITY) == 0);
  for (int invalid : {INT_MIN, -1, 0, 1, 2, 3, 5333334, INT_MAX}) {
    assert(!period.set(invalid));
    assert(period.cycles == 320000 && period.scale == 16);
  }
  puts("PWM period/duty bounds, quantization, endpoints and invalid-input preservation PASS");
}
