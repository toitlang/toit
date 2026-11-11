// Copyright (C) 2026 Toit contributors.
// Probe: bit tests on a byte (the loop of Utils::bytes_in_utf_8_sequence)
// by bit-blasting with VeriFast's bitops.gh (Z_of_uint8).
#include <stdint.h>
//@ #include <bitops.gh>

/*@
lemma void byte_and_128(int p)
  requires 0 <= p &*& p < 256;
  ensures (p & 128) == (p >= 128 ? 128 : 0);
{
  Z z = Z_of_uint8(p);
  Z m = Z_of_uint8(128);
  bitand_def(p, z, 128, m);
}
@*/

int test(uint8_t p)
//@ requires true;
//@ ensures result == (p >= 128 ? 1 : 0);
{
  //@ byte_and_128(p);
  return (p & 128) != 0 ? 1 : 0;
}
