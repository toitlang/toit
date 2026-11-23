// Copyright (C) 2026 Toit contributors.

// ESBMC includes these same definitions and compares their results to src/objects.h.
// VeriFast checks that they implement the contracts imported by the C++ renderings.
#ifndef __cplusplus
#include <objects.gen.h>
#endif

bool Smi_is_valid(int64 value)
//@ requires true;
//@ ensures result == smi_range(value);
{
  int64 max = (int64)(UINTPTR_MAX / 4);
  return -max - 1 <= value && value <= max;
}

word Smi_value__Smip(Smi *smi)
//@ requires is_smi_w((uword)smi) == true;
//@ ensures result == smi_val((uword)smi) &*& smi_range(result) == true;
{
  uword bits = (uword)smi;
  word value = bits <= UINTPTR_MAX / 2 ? (word)bits : -1 - (word)(UINTPTR_MAX - bits);
  return value / 2;
}

word Smi_value__Objectp(Object *object)
//@ requires is_smi_w((uword)object) == true;
//@ ensures result == smi_val((uword)object) &*& smi_range(result) == true;
{
  return Smi_value__Smip((Smi *)(uword)object);
}

Smi *Smi_from(word value)
//@ requires smi_range(value) == true;
/*@ ensures is_smi_w((uword)result) == true &*& smi_val((uword)result) == value &*&
            (0 <= value ? result == smi_ptr(value) &*& (uword)result == 2 * value : true); @*/
{
  word twice = 2 * value;
  uword bits = twice >= 0 ? (uword)twice : UINTPTR_MAX - (uword)(-1 - twice);
  return (Smi *)bits;
}
