// Copyright (C) 2022 Toitware ApS.
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

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(esp32, MODULE_ESP32)

TYPE_PRIMITIVE_ANY(ota_begin)
TYPE_PRIMITIVE_ANY(ota_write)
TYPE_PRIMITIVE_ANY(ota_end)
TYPE_PRIMITIVE_ANY(ota_state)
TYPE_PRIMITIVE_ANY(ota_validate)
TYPE_PRIMITIVE_ANY(ota_rollback)
TYPE_PRIMITIVE_ANY(reset_reason)
TYPE_PRIMITIVE_ANY(enable_external_wakeup)
TYPE_PRIMITIVE_ANY(enable_touchpad_wakeup)
TYPE_PRIMITIVE_ANY(wakeup_cause)
TYPE_PRIMITIVE_ANY(ext1_wakeup_status)
TYPE_PRIMITIVE_ANY(touchpad_wakeup_status)
TYPE_PRIMITIVE_ANY(total_deep_sleep_time)
TYPE_PRIMITIVE_ANY(total_run_time)
TYPE_PRIMITIVE_ANY(get_mac_address)
TYPE_PRIMITIVE_ANY(rtc_user_bytes)
TYPE_PRIMITIVE_ANY(memory_page_report)

}  // namespace toit::compiler
}  // namespace toit
