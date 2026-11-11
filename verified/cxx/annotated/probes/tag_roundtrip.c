// Copyright (C) 2026 Toit contributors.
// Probe: how VeriFast treats a pointer converted to an integer, tagged,
// converted back and untagged (the shape of HeapObject::_raw_at).
#include <stdint.h>
typedef intptr_t word;
typedef uintptr_t uword;

// (1) Round trip starting from a raw pointer: tag, untag, dereference.
word read_roundtrip(word *raw)
//@ requires intptr(raw, ?v) &*& (uword)raw < UINTPTR_MAX;
//@ ensures intptr(raw, v) &*& result == v;
{
  void *tagged = (void *)((uword)raw + 1);
  word *p = (word *)((uword)tagged - 1);
  // The integer-to-pointer cast yields a pointer with the null provenance;
  // the chunk is at `raw` (the allocation's provenance): no match. This is
  // VeriFast's model of PNVI: sound, and unprovable without an assumption
  // that the cast recovers the provenance (see tests/provenance0.c of
  // VeriFast: `assume(p == (T *)(uintptr_t)p)`).
  return *p; //~should_fail
}

// (2) Starting from the tagged pointer (what objects.h does: `this` is the
// tagged value).
word read_tagged(void *tagged)
//@ requires 1 <= (uword)tagged &*& intptr((word *)((uword)tagged - 1), ?v);
//@ ensures intptr((word *)((uword)tagged - 1), v) &*& result == v;
{
  word *p = (word *)((uword)tagged - 1);
  return *p;
}
