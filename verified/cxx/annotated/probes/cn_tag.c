// Copyright (C) 2026 Toit contributors.
// Probe: CN (rems-project/cn) on the tagged-pointer read of objects.h.
#include <stdint.h>

// (1) The word at the untagged address, read through the integer round
// trip, with the ownership stated at a pointer derived from `raw`.
intptr_t read_roundtrip(intptr_t *raw)
/*@ requires take v = RW<intptr_t>(raw);
             (integer) raw < 18446744073709551615;
    ensures take v2 = RW<intptr_t>(raw);
            v2 == v;
            return == v; @*/
{
  void *tagged = (void *)((uintptr_t)raw + 1);
  intptr_t *p = (intptr_t *)((uintptr_t)tagged - 1);
  return *p;
}

// (2) Through the code's own expression, as VeriFast accepts it.
intptr_t read_tagged(void *tagged)
/*@ requires (integer) tagged >= 1;
             take v = RW<intptr_t>(array_shift<char>(tagged, -1));
    ensures take v2 = RW<intptr_t>(array_shift<char>(tagged, -1));
            return == v; @*/
{
  intptr_t *p = (intptr_t *)((uintptr_t)tagged - 1);
  return *p;
}
