// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(stdio, MODULE_STDIO)

TYPE_PRIMITIVE_ANY(stdin_init)
TYPE_PRIMITIVE_ANY(stdin_open)
TYPE_PRIMITIVE_ANY(stdin_read)

}  // namespace toit::compiler
}  // namespace toit
