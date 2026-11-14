// Copyright (C) 2026 Toit contributors.
// Use of this source is governed by tests/LICENSE.
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include "main/wire.h"
#include "main/verify.h"

static void put(uint8_t *bytes, size_t bit, unsigned value) {
  unsigned mask = 1u << (7 - bit % 8);
  bytes[bit / 8] = (bytes[bit / 8] & ~mask) | (value ? mask : 0);
}

int main(int argc, char **argv) {
  assert(argc == 3);
  unsigned bits = atoi(argv[1]);
  assert(bits == 16 || bits == 24 || bits == 32);
  size_t cycle = 251 * 2 * bits;
  uint8_t reference[251 * 8], capture[251 * 8 + 64];
  FILE *f = fopen(argv[2], "rb");
  assert(f && fread(reference, 1, cycle / 8, f) == cycle / 8 && fgetc(f) == EOF);
  fclose(f);
  // Validate the firmware's reference generation against the independently
  // exported permanent Toit pattern, including its wire byte order.
  for (size_t bit = 0; bit < cycle; bit++) {
    unsigned value = sample(bit / (2 * bits), (bit / bits) % 2, bits);
    assert(wire_bit(reference, bit) == ((value >> (bits - 1 - bit % bits)) & 1));
  }
  for (size_t phase = 0; phase < cycle; phase++) {
    size_t length = cycle + 103;
    for (size_t bit = 0; bit < length; bit++) put(capture, bit, wire_bit(reference, (phase + bit) % cycle));
    WireResult result = wire_check(capture, length, reference, cycle);
    assert(result.phase == (int)phase && !result.errors && result.checked == length);
    // A corruption after the anchor must be counted exactly, never skipped.
    size_t corrupt = 96 + phase % (length - 96);
    put(capture, corrupt, !wire_bit(capture, corrupt));
    result = wire_check(capture, length, reference, cycle);
    assert(result.phase == (int)phase && result.errors == 1 && result.first_error == corrupt);
    // A damaged first anchor cannot be rescued by a later clean frame.
    put(capture, 17, !wire_bit(capture, 17));
    result = wire_check(capture, length, reference, cycle);
    assert(result.phase < 0 && result.checked == 0);
  }
  assert(wire_check(capture, cycle, reference, cycle).phase < 0);
  memset(capture, 0, sizeof(capture));
  assert(wire_check(capture, cycle + 103, reference, cycle).phase < 0);
  memset(reference, 0, sizeof(reference));
  assert(wire_check(capture, cycle + 103, reference, cycle).phase == -2);
  printf("WIRE CHECK PASS bits=%u all_phases=%zu\n", bits, cycle);
}
