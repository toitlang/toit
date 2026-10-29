// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(signal, MODULE_SIGNAL)

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(watch)
TYPE_PRIMITIVE_NULL(unwatch)
TYPE_PRIMITIVE_NULL(reset)
TYPE_PRIMITIVE_NULL(ignore)
TYPE_PRIMITIVE_NULL(raise)
TYPE_PRIMITIVE_ANY(number)

}  // namespace toit::compiler
}  // namespace toit
