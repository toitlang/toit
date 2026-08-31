// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(terminal, MODULE_TERMINAL)

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_BOOL(is_terminal)
TYPE_PRIMITIVE_ANY(enter_raw)
TYPE_PRIMITIVE_NULL(restore)
TYPE_PRIMITIVE_ARRAY(size)
TYPE_PRIMITIVE_ANY(resize_init)
TYPE_PRIMITIVE_ANY(resize_watch)
TYPE_PRIMITIVE_NULL(resize_unwatch)

}  // namespace toit::compiler
}  // namespace toit
