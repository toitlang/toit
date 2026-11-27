// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "type_primitive.h"

namespace toit {
namespace compiler {
MODULE_TYPES(rp2350, MODULE_RP2350)
TYPE_PRIMITIVE_INT(boot_partition)
TYPE_PRIMITIVE_BOOL(is_trial)
TYPE_PRIMITIVE_NULL(validate)
TYPE_PRIMITIVE_NULL(rollback)
TYPE_PRIMITIVE_INT(inactive_size)
TYPE_PRIMITIVE_NULL(inactive_erase)
TYPE_PRIMITIVE_NULL(inactive_write)
TYPE_PRIMITIVE_NULL(upgrade)
TYPE_PRIMITIVE_NULL(stage)
TYPE_PRIMITIVE_BYTE_ARRAY(unique_id)
TYPE_PRIMITIVE_NULL(watchdog_start)
TYPE_PRIMITIVE_NULL(watchdog_feed)
TYPE_PRIMITIVE_NULL(watchdog_stop)
TYPE_PRIMITIVE_BOOL(watchdog_caused_reset)
TYPE_PRIMITIVE_BOOL(woke_from_deep_sleep)
}  // namespace compiler
}  // namespace toit
