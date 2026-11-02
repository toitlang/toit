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

#include "primitive.h"

namespace toit {

// Bytecodes refer to primitives by module and index, which is what these
// tables are for. Native code calls the primitives directly, so it doesn't
// have the tables, which means that it only has the primitives it uses.

#define MODULE_ENUM(name, entries) INDEX_##name,
enum {
  MODULES(MODULE_ENUM)
  COUNT
};
#undef MODULE_ENUM

#define MODULE_PRIMITIVES_WEAK(name, entries) \
  const PrimitiveEntry* name##_primitives_ __attribute__((weak)) = null;
#define MODULE_PRIMITIVES(name, entries) \
  primitives_[INDEX_##name] = name##_primitives_;

const PrimitiveEntry* Primitive::primitives_[COUNT];
const unsigned Primitive::primitive_counts_[COUNT] = {
  MODULES(MODULE_PRIMITIVE_COUNT)
};
static_assert(Primitive::MODULE_COUNT == COUNT, "Inconsistent module count");

MODULES(MODULE_PRIMITIVES_WEAK)
void Primitive::set_up() {
  MODULES(MODULE_PRIMITIVES)
}

#undef MODULE_PRIMITIVES_WEAK
#undef MODULE_PRIMITIVES

}  // namespace toit
