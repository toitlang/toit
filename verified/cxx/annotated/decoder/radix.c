// Copyright (C) 2026 Toit contributors.
//
// The proofs of radix.h (run.sh: `radix`, Z3, LP64 and ILP32).

#include "radix.h"

/*@
lemma void pow7(int s)
  requires 0 <= s;
  ensures pow_nat(2, nat_of_int(s + 7)) == 128 * pow_nat(2, nat_of_int(s));
{
  succ_int(s);
  succ_int(s + 1);
  succ_int(s + 2);
  succ_int(s + 3);
  succ_int(s + 4);
  succ_int(s + 5);
  succ_int(s + 6);
}

lemma void emit_digit(int v, int k, int acc)
  requires 128 <= v &*& 0 <= k &*& k <= 9 &*& 0 <= acc &*& acc < pow128(k) &*&
           acc + v * pow128(k) <= 18446744073709551615;
  ensures k < 9 &*& cardinal_width(v) == 1 + cardinal_width(v / 128) &*&
          0 <= v % 128 &*& v % 128 < 128 &*& acc + (v % 128) * pow128(k) < pow128(k + 1) &*&
          acc + v * pow128(k) == acc + (v % 128) * pow128(k) + (v / 128) * pow128(k + 1);
{
  div_rem_nonneg(v, 128);
  if (k == 0) {} else if (k == 1) {} else if (k == 2) {} else if (k == 3) {} else if (k == 4) {}
  else if (k == 5) {} else if (k == 6) {} else if (k == 7) {} else if (k == 8) {} else {}
}

lemma void last_digit(int v, int k, int acc)
  requires 0 <= v &*& v < 128 &*& 0 <= k &*& k <= 9 &*& 0 <= acc &*& acc < pow128(k) &*&
           acc + v * pow128(k) <= 18446744073709551615;
  ensures v <= 18446744073709551615 / pow128(k);
{
  if (k == 0) {} else if (k == 1) {} else if (k == 2) {} else if (k == 3) {} else if (k == 4) {}
  else if (k == 5) {} else if (k == 6) {} else if (k == 7) {} else if (k == 8) {} else {}
}

lemma void digit_pow(int k)
  requires 0 <= k &*& k <= 9;
  ensures pow_nat(2, nat_of_int(7 * k)) == pow128(k);
{
  nat_of_zero();
  pow7(0);
  if (k >= 2) pow7(7);
  if (k >= 3) pow7(14);
  if (k >= 4) pow7(21);
  if (k >= 5) pow7(28);
  if (k >= 6) pow7(35);
  if (k >= 7) pow7(42);
  if (k >= 8) pow7(49);
  if (k >= 9) pow7(56);
}

lemma void digit_step(int r, int d, int k)
  requires 0 <= k &*& 7 * k < 64 &*& 0 <= r &*& r < pow128(k) &*&
           0 <= d &*& d < 128 &*& d <= 18446744073709551615 / pow128(k);
  ensures r + d * pow128(k) <= 18446744073709551615 &*& (k < 9 ? r + d * pow128(k) < pow128(k + 1) : true);
{
  if (k == 0) {} else if (k == 1) {} else if (k == 2) {} else if (k == 3) {} else if (k == 4) {}
  else if (k == 5) {} else if (k == 6) {} else if (k == 7) {} else if (k == 8) {} else {}
}
@*/
