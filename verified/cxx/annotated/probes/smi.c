// Copyright (C) 2026 Toit contributors.
// Probe: the Smi encoding of objects.h under VeriFast (tag test with `&`,
// pointer-to-signed-integer conversion, arithmetic shift).
#include <stdint.h>
#include <stdbool.h>
//@ #include <bitops.gh>
typedef intptr_t word;
typedef uintptr_t uword;
struct Object;
typedef struct Object Object;

bool is_smi(Object *o)
//@ requires true;
//@ ensures result == ((uword)o % 2 == 0);
{
  //@ bitand_pow_nat((uword)o, N1);
  return ((uword)o & 1) == 0;
}

word smi_value(Object *o)
//@ requires (uword)o % 2 == 0;
//@ ensures true;
{
  return (/*@ truncating @*/ (word)(uword)o) >> 1;  // objects.h: reinterpret_cast<word>(o) >> 1
}
