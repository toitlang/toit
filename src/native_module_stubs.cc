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
#include "objects_inline.h"
#include "process.h"

namespace toit {

// Generated native code calls the primitives it uses directly. This is the
// last library on the link line, so these are only used for the primitives
// that the platform doesn't have. Calling them fails when the program runs.
#define PRIMITIVE_STUB(name, arity)                                                    \
  __attribute__((weak)) Object* p_##name(Process* process, Object** __args) {          \
    return Primitive::mark_as_error(process->program()->unimplemented());              \
  }
#define MODULE_STUB(name, entries) namespace name##_module { entries(PRIMITIVE_STUB) }
MODULES(MODULE_STUB)
#undef MODULE_STUB
#undef PRIMITIVE_STUB

}  // namespace toit
