// Copyright (C) 2026 Toit contributors.
//
// The proof of cardinal.h's step lemma (run.sh: `cardinal`, Z3, LP64 and
// ILP32).

#include "cardinal.h"

/*@
lemma void cardinal_step(int v, int k)
  requires 128 <= v &*& v <= UINTPTR_MAX / p128(k) &*& 0 <= k &*& k <= 9;
  ensures k + 1 <= 9 &*& v / 128 <= UINTPTR_MAX / p128(k + 1);
{
  div_rem_nonneg(v, 128);
}
@*/
