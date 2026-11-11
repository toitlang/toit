// Copyright (C) 2026 Toit contributors.
// Probe: does frama-clang (Frama-C's C++ front end) accept the real
// src/objects.h, and what does WP make of the tagged-pointer accessors?
#include "objects.h"

namespace toit {

/*@ requires \true;
    assigns \nothing;
    ensures \result == ((((uword)o) & 1) == 0); */
bool probe_is_smi(Object* o) {
  return is_smi(o);
}

/*@ requires \valid_read((Object**)(((uword)a) - 1) + (0 .. 2));
    requires *((uword*)(((uword)a) - 1) + 1) == 1;
    assigns \nothing; */
Object* probe_array_at0(Array* a) {
  return a->at(0);
}

}
