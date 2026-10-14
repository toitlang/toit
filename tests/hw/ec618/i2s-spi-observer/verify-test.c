// Copyright (C) 2026 Toit contributors.
// Use of this source is governed by tests/LICENSE.
#include <assert.h>
#include <stdio.h>
#include "main/verify.h"
static void frame(Verify *v, uint32_t l, uint32_t r) {
  uint8_t bytes[8];
  unsigned n = v->bits / 8;
  for (unsigned i = 0; i < n; i++) { bytes[i] = l >> (8*i); bytes[n+i] = r >> (8*i); }
  verify_data(v, bytes, n*2);
}
int main(void) {
  assert(sample(209, false, 24) == 0x0d6b49);
  assert(sample(209, true, 24) == 0x9dbf51);
  assert(sample(134, false, 24) == 0x5a3c1e);
  assert(sample(134, true, 24) == 0x496b85);
  for (unsigned bits = 16; bits <= 32; bits += 8) {
    for (unsigned training = 7; training <= 8; training++) {
      Verify v; verify_init(&v, bits);
      for (unsigned i = 0; i < training; i++) frame(&v, 0, 0);
      for (unsigned i = 0; i < 2000; i++) {
        uint32_t l = sample(i%251, false, bits), r = sample(i%251, true, bits);
        if (i == 900) r = l;
        frame(&v, l, r);
      }
      assert(v.started && !v.invalid && v.frames == 2000 && v.errors == 1);
      assert(v.first_frame == 900 && v.first_right == sample(900%251, false, bits));
      assert(v.records[0].frame == 900 && v.records[0].right == v.first_right);
    }
    Verify v; verify_init(&v, bits);
    frame(&v, 123, 456);
    for (unsigned i = 0; i < 7; i++) frame(&v, 0, 0);
    frame(&v, sample(0,false,bits), sample(0,true,bits));
    assert(v.started && !v.invalid && !v.errors);
    verify_init(&v, bits);
    for (unsigned i = 0; i < 9; i++) frame(&v, 0, 0);
    assert(v.invalid);
    verify_init(&v, bits);
    for (unsigned i = 0; i < 7; i++) frame(&v, 0, 0);
    frame(&v, sample(1,false,bits), sample(1,true,bits));
    assert(v.invalid);
    verify_init(&v, bits);
    uint8_t bad[1] = {0}; verify_data(&v, bad, 1); assert(v.invalid);
  }
Verify bounded; verify_init(&bounded, 24);
for (unsigned i = 0; i < 8; i++) frame(&bounded, 0, 0);
frame(&bounded, sample(0, false, 24), sample(0, true, 24));
for (unsigned i = 1; i <= 100; i++) frame(&bounded, sample(i % 251, false, 24), sample(i % 251, true, 24) ^ 1);
assert(bounded.frames == 101 && bounded.errors == 100 && !bounded.invalid);
for (unsigned i = 0; i < VERIFY_RECORDS; i++) {
  assert(bounded.records[i].frame == i + 1);
  assert(bounded.records[i].right == (sample((i + 1) % 251, true, 24) ^ 1));
}
  puts("Native stream verifier: widths, bounded startup, corruption and no resynchronization PASS");
}
