// Copyright (C) 2026 Toit contributors.
// Private diagnostic; use of this source is governed by tests/LICENSE.
#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct {
  int phase;
  size_t checked, errors, first_error;
} WireResult;

static unsigned wire_bit(const uint8_t *bytes, size_t bit) {
  return (bytes[bit / 8] >> (7 - bit % 8)) & 1;
}

// Anchor only at the beginning of the window. Never skip bad bits or
// resynchronize later in the capture. The reference is a complete cycle of
// MSB-first serial stereo samples, independent of DMA sample packing.
static WireResult wire_check(const uint8_t *data, size_t length,
                             const uint8_t *reference, size_t cycle) {
  WireResult result = {.phase = -1};
  if (length < cycle + 96 || cycle < 96) return result;
  for (size_t phase = 0; phase < cycle; phase++) {
    size_t bit = 0;
    while (bit < 96 && wire_bit(data, bit) == wire_bit(reference, (phase + bit) % cycle)) bit++;
    if (bit != 96) continue;
    if (result.phase >= 0) { result.phase = -2; return result; }
    result.phase = phase;
  }
  if (result.phase < 0) return result;
  for (size_t bit = 0; bit < length; bit++) {
    if (wire_bit(data, bit) != wire_bit(reference, (result.phase + bit) % cycle)) {
      if (!result.errors) result.first_error = bit;
      result.errors++;
    }
  }
  result.checked = length;
  return result;
}
