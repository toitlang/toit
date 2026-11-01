// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#pragma once

#include "interpreter.h"
#include "native_abi.h"
#include "objects.h"
#include "objects_inline.h"
#include "process.h"
#include "program.h"

// Support for programs that have been compiled to C++. See native_abi.h.
//
// A process runs either bytecodes or native code; never both.

namespace toit {

// Used for checking that the running program is the one that was compiled.
inline uint32 native_fingerprint(const uint8* bytes, word length) {
  uint32 hash = 2166136261u;
  for (word i = 0; i < length; i++) hash = (hash ^ bytes[i]) * 16777619u;
  return hash;
}

}  // namespace toit
