// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in tests/LICENSE.

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "../../src/resources/i2s_clock_ec618.h"

using toit::I2sClockPlan;

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #condition); \
    exit(1); \
  } \
} while (0)

static void verify(int rate, int bits, int multiplier) {
  I2sClockPlan plan = {};
  CHECK(I2sClockPlan::calculate(rate, bits, multiplier, &plan));
  CHECK(plan.integer >= 1 && plan.integer <= 256);
  CHECK(plan.fraction < (1u << 24));
  CHECK(plan.integer != 256 || plan.fraction == 0);
  CHECK(plan.output_divider > 0);
  CHECK(plan.bit_clock_divider > 0);
  // Reconstruct the actual wire clocks independently from the integer and
  // fractional divider fields, rather than duplicating the planning steps.
  double fractional = plan.integer + plan.fraction / double(1u << 24);
  double mclk = 409600000.0 / fractional / plan.output_divider;
  double bclk = mclk / plan.bit_clock_divider;
  CHECK(fabs(mclk / (double(rate) * multiplier) - 1) < 0.00000005);
  CHECK(fabs(bclk / (double(rate) * bits * 2) - 1) < 0.00000005);
}

int main() {
  // The measured root is 409.6 MHz despite the vendor's 408 MHz selector
  // name and sample-rate table. At 256fs with a divide-by-four output these
  // rates require exact integers, a half, a third, or a sixth respectively.
  // Using the vendor table makes the physical clocks about 0.392% too fast.
  const uint32_t reference[][3] = {
    {8000, 50, 0}, {16000, 25, 0}, {32000, 12, 0x800000},
    {48000, 8, 0x555555}, {96000, 4, 0x2aaaab},
  };
  for (const auto& row : reference) {
    I2sClockPlan plan = {};
    CHECK(I2sClockPlan::calculate(row[0], 16, 256, &plan));
    CHECK(plan.integer == row[1]);
    CHECK(llabs(int64_t(plan.fraction) - row[2]) <= 1);
    CHECK(plan.output_divider == 4);
  }
  const int multipliers[] = {128, 256, 384, 512, 576, 768, 1024, 1152};
  for (int rate = 1000; rate <= 96000; rate += 137) {
    for (int multiplier : multipliers) {
      verify(rate, 8, multiplier);
      verify(rate, 16, multiplier);
      if (multiplier % 3 == 0) verify(rate, 24, multiplier);
      verify(rate, 32, multiplier);
    }
  }
  for (int multiplier : multipliers) {
    verify(96000, 8, multiplier);
    verify(96000, 16, multiplier);
    if (multiplier % 3 == 0) verify(96000, 24, multiplier);
    verify(96000, 32, multiplier);
  }
  verify(100, 16, 128);  // Requires an output divider greater than four.
  I2sClockPlan plan = {};
  CHECK(!I2sClockPlan::calculate(1, 16, 128, &plan));
  CHECK(!I2sClockPlan::calculate(0, 16, 256, &plan));
  CHECK(!I2sClockPlan::calculate(-1, 16, 256, &plan));
  CHECK(!I2sClockPlan::calculate(96001, 16, 256, &plan));
  CHECK(!I2sClockPlan::calculate(48000, 12, 384, &plan));
  CHECK(!I2sClockPlan::calculate(48000, 24, 256, &plan));
  CHECK(!I2sClockPlan::calculate(48000, 16, 0, &plan));
  CHECK(!I2sClockPlan::calculate(48000, 32, 255, &plan));
  puts("EC618 I2S clock planning PASS");
}
