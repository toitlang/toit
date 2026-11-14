// Copyright (C) 2026 Toit contributors.
// Use of this source is governed by tests/LICENSE.
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "main/wire.h"

int main(int argc, char **argv) {
  assert(argc == 2);
  uint8_t reference[251 * 6];
  FILE *f = fopen(argv[1], "rb");
  assert(f && fread(reference, 1, sizeof(reference), f) == sizeof(reference));
  assert(fgetc(f) == EOF);
  fclose(f);
  size_t length = ((96000 * 6 * 2 + 4091) / 4092) * 4092;
  uint8_t *capture = malloc(length);
  assert(capture);
  for (size_t i = 0; i < length; i++) capture[i] = reference[i % sizeof(reference)];
  WireResult r = wire_check(capture, length * 8, reference, sizeof(reference) * 8);
  assert(r.phase == 0 && !r.errors && r.checked == length * 8);
  capture[length - 1] ^= 1;
  r = wire_check(capture, length * 8, reference, sizeof(reference) * 8);
  assert(r.errors == 1 && r.first_error == length * 8 - 1);
  capture[length - 1] ^= 1;
  // Replaying or skipping a DMA block must not cause resynchronization.
  memcpy(capture + 4092, capture, 4092);
  r = wire_check(capture, length * 8, reference, sizeof(reference) * 8);
  assert(r.errors && r.first_error >= 4092 * 8 && r.first_error < 8192 * 8);
  for (size_t i = 4092; i < length; i++) capture[i] = reference[(i + 4092) % sizeof(reference)];
  r = wire_check(capture, length * 8, reference, sizeof(reference) * 8);
  assert(r.errors && r.first_error >= 4092 * 8 && r.first_error < 8192 * 8);
  free(capture);
  puts("Continuous two-second pattern, final-bit corruption, replay and drop PASS");
}
