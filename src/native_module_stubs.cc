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

// Generated native code references the primitive modules it uses, which
// makes the linker include them. This is the last library on the link line,
// so these definitions are only used for the modules that the platform
// doesn't have. Calling the primitives of those modules fails at runtime.
#define MODULE_STUB(name, entries) __attribute__((weak)) char name##_module_linked_ = 0;
MODULES(MODULE_STUB)
#undef MODULE_STUB

}  // namespace toit
