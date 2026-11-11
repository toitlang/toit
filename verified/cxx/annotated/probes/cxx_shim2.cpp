// Copyright (C) 2026 Toit contributors.
// Probe: which other constructs of src/objects.h VeriFast's C++ front end
// accepts: an integral static_cast, and an inline function without a
// contract (objects.h has several hundred).
typedef long word;
typedef unsigned long uword;

inline uword no_contract(word x) { return x + 1; }

uword to_unsigned(int tag)
//@ requires 0 <= tag;
//@ ensures result == tag;
{
  return static_cast<uword>(tag);
}
