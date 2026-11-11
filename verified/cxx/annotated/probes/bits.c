// Copyright (C) 2026 Toit contributors.
// Probe: the bit-level facts of the header encoding under VeriFast.
#include <stdint.h>
//@ #include <bitops.gh>
typedef intptr_t word;
typedef uintptr_t uword;

/*@

lemma void pow2_pos(nat n)
  requires true;
  ensures 0 < pow_nat(2, n);
{
  switch (n) {
    case zero:
    case succ(n0): pow2_pos(n0);
  }
}

lemma void Z_shiftright_div(Z z, nat n)
  requires 0 <= int_of_Z(z);
  ensures int_of_Z(Z_shiftright(z, n)) == int_of_Z(z) / pow_nat(2, n);
{
  switch (n) {
    case zero:
      div_rem_nonneg_unique(int_of_Z(z), 1, int_of_Z(z), 0);
    case succ(n0):
      pow2_pos(n0);
      switch (z) {
        case Zsign(b):
          div_rem_nonneg_unique(0, pow_nat(2, n), 0, 0);
        case Zdigit(z0, b0):
          int a = int_of_Z(z0);
          Z_shiftright_div(z0, n0);
          int p = pow_nat(2, n0);
          div_rem_nonneg(a, p);
          div_rem_nonneg(2 * a + (b0 ? 1 : 0), 2 * p);
          int q = a / p;
          int r = a % p;
          // 2a + b = 2p q + (2r + b), 0 <= 2r + b < 2p
          div_rem_nonneg_unique(2 * a + (b0 ? 1 : 0), 2 * p, q, 2 * r + (b0 ? 1 : 0));
      }
  }
}

lemma void shiftright_div(int x, nat n)
  requires 0 <= x &*& x <= UINTPTR_MAX;
  ensures x >> int_of_nat(n) == x / pow_nat(2, n);
{
  Z z = int_of_Z_of_uintN(x, N64);
  shiftright_def(x, z, n);
  Z_shiftright_div(z, n);
}

@*/

word shift5(word x)
//@ requires 0 <= x;
//@ ensures result == x / 32;
{
  //@ shiftright_div(x, N5);
  return x >> 5;
}

uword mask_all(word x)
//@ requires 0 <= x;
//@ ensures result == x;
{
  //@ bitand_pow_nat(x, N64);
  return (uword)x & (/*@ truncating @*/ (uword)-1);  // C++: x & CLASS_ID_MASK (word & uword); VeriFast needs the conversion explicit
}

uword tag_bits(uword hw)
//@ requires true;
//@ ensures result == (hw & 30);
{
  int shift = 0 + 1;
  uword mask = (uword)15 << shift;
  return hw & mask;
}
