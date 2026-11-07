// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "type_primitive.h"
namespace toit {
namespace compiler {
MODULE_TYPES(pio, MODULE_PIO)
TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(create)
TYPE_PRIMITIVE_ANY(close)
TYPE_PRIMITIVE_ANY(control)
TYPE_PRIMITIVE_ANY(frequency)
TYPE_PRIMITIVE_ANY(submit)
TYPE_PRIMITIVE_ANY(status)
TYPE_PRIMITIVE_ANY(transferred)
TYPE_PRIMITIVE_ANY(cancel)
TYPE_PRIMITIVE_ANY(take)
TYPE_PRIMITIVE_ANY(discard)
TYPE_PRIMITIVE_ANY(irq_clear)
}  // namespace compiler
}  // namespace toit
