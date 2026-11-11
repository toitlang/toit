// Copyright (C) 2026 Toit contributors.
//
// The digits of MessageDecoder::read_cardinal: before the k-th digit the
// shift is 7k and the result is below 2^(7k) = pow128(k); a digit d < 128
// with d <= UINTPTR_MAX >> 7k keeps the result in the word and below
// 2^(7k + 7). The lemmas are proved in radix.c (with Z3: the powers of 128
// are case split, so the products are linear); the decoder uses their
// prototypes.

#ifndef TOIT_VF_RADIX_H
#define TOIT_VF_RADIX_H

//@ #include <nat.gh>

/*@
// 2^(7k), k <= 9 (encoder/cardinal.h has the same table as p128).
fixpoint int pow128(int k) {
  return k == 0 ? 1 : k == 1 ? 128 : k == 2 ? 16384 : k == 3 ? 2097152 : k == 4 ? 268435456 :
         k == 5 ? 34359738368 : k == 6 ? 4398046511104 : k == 7 ? 562949953421312 :
         k == 8 ? 72057594037927936 : 9223372036854775808;
}

// The shift of the k-th digit, as the shift operators see it.
lemma void digit_pow(int k);
  requires 0 <= k &*& k <= 9;
  ensures pow_nat(2, nat_of_int(7 * k)) == pow128(k);

lemma void digit_step(int r, int d, int k);
  requires 0 <= k &*& 7 * k < 8 * sizeof(void *) &*& 0 <= r &*& r < pow128(k) &*&
           0 <= d &*& d < 128 &*& d <= UINTPTR_MAX / pow128(k);
  ensures r + d * pow128(k) <= UINTPTR_MAX &*& (k < 9 ? r + d * pow128(k) < pow128(k + 1) : true);
@*/

#endif
