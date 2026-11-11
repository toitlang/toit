// Copyright (C) 2026 Toit contributors.
// Probe: does VeriFast's C++ front end accept the real src/objects.h?
#include "objects.h"

namespace toit {

bool probe_is_smi(Object* o)
//@ requires true;
//@ ensures true;
{
  return is_smi(o);
}

}
