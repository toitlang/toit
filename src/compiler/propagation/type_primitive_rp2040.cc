// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "type_primitive.h"

namespace toit {
namespace compiler {
MODULE_TYPES(rp2040, MODULE_RP2040)
TYPE_PRIMITIVE_BYTE_ARRAY(unique_id)
TYPE_PRIMITIVE_NULL(system_watchdog_feed)
TYPE_PRIMITIVE_NULL(firmware_submit)
TYPE_PRIMITIVE_SMI(firmware_status)
TYPE_PRIMITIVE_BOOL(recovery_requested)
}  // namespace compiler
}  // namespace toit
