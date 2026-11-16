// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

#include "type_primitive.h"

namespace toit {
namespace compiler {
MODULE_TYPES(power, MODULE_POWER)
TYPE_PRIMITIVE_NULL(check_reset)
TYPE_PRIMITIVE_INT(prepare_sleep)
TYPE_PRIMITIVE_BOOL(supports_timed_sleep)
TYPE_PRIMITIVE_INT(reset_reason)
TYPE_PRIMITIVE_NULL(configure_wakeup_pin)
}  // namespace compiler
}  // namespace toit
