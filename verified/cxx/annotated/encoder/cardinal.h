// Copyright (C) 2026 Toit contributors.
//
// The bound of the bytes MessageEncoder::write_cardinal writes: before the
// k-th byte the value is below 2^(W - 7k), so a word takes at most 10
// bytes (5 on 32-bit). The step lemma is proved in cardinal.c (with Z3:
// divisions by the powers of 128 on either width); the encoder uses its
// prototype, so that the encoder itself verifies with VeriFast's default
// prover.

#ifndef TOIT_VF_CARDINAL_H
#define TOIT_VF_CARDINAL_H

/*@
fixpoint int p128(int k) {
  return k == 0 ? 1 : k == 1 ? 128 : k == 2 ? 16384 : k == 3 ? 2097152 : k == 4 ? 268435456 :
         k == 5 ? 34359738368 : k == 6 ? 4398046511104 : k == 7 ? 562949953421312 :
         k == 8 ? 72057594037927936 : 9223372036854775808;
}

lemma void cardinal_step(int v, int k);
  requires 128 <= v &*& v <= UINTPTR_MAX / p128(k) &*& 0 <= k &*& k <= 9;
  ensures k + 1 <= 9 &*& v / 128 <= UINTPTR_MAX / p128(k + 1);
@*/

#endif
