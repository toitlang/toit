// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "type_primitive.h"
namespace toit {
namespace compiler {
MODULE_TYPES(zephyr, MODULE_ZEPHYR)
TYPE_PRIMITIVE_INT(reset_reason)
TYPE_PRIMITIVE_INT(supported_reset_reasons)
TYPE_PRIMITIVE_NULL(watchdog_start)
TYPE_PRIMITIVE_NULL(watchdog_feed)
TYPE_PRIMITIVE_NULL(watchdog_stop)
TYPE_PRIMITIVE_INT(prepare_poweroff)
TYPE_PRIMITIVE_INT(validate_sleep)
}  // namespace compiler
}  // namespace toit
