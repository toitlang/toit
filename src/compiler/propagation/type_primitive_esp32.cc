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

TYPE_PRIMITIVE_STRING(ota_current_partition_name)
TYPE_PRIMITIVE_NULL(ota_begin)
TYPE_PRIMITIVE_SMI(ota_write)
TYPE_PRIMITIVE_SMI(ota_end)
TYPE_PRIMITIVE_SMI(ota_state)
TYPE_PRIMITIVE_BOOL(ota_validate)

TYPE_PRIMITIVE(ota_rollback) {
  failure.add_string(program);
}

TYPE_PRIMITIVE_SMI(reset_reason)
TYPE_PRIMITIVE_NULL(enable_external_wakeup)
TYPE_PRIMITIVE_NULL(enable_touchpad_wakeup)
TYPE_PRIMITIVE_SMI(wakeup_cause)
TYPE_PRIMITIVE_INT(ext1_wakeup_status)
TYPE_PRIMITIVE_INT(touchpad_wakeup_status)
TYPE_PRIMITIVE_INT(total_deep_sleep_time)
TYPE_PRIMITIVE_BYTE_ARRAY(get_mac_address)
TYPE_PRIMITIVE_BYTE_ARRAY(memory_page_report)
TYPE_PRIMITIVE_NULL(watchdog_init)
TYPE_PRIMITIVE_NULL(watchdog_reset)
TYPE_PRIMITIVE_NULL(watchdog_deinit)
TYPE_PRIMITIVE_NULL(pin_hold_enable)
TYPE_PRIMITIVE_NULL(pin_hold_disable)
TYPE_PRIMITIVE_NULL(deep_sleep_pin_hold_enable)
TYPE_PRIMITIVE_NULL(deep_sleep_pin_hold_disable)
TYPE_PRIMITIVE_NULL(pm_configure)
TYPE_PRIMITIVE_ARRAY(pm_get_configuration)
TYPE_PRIMITIVE_BYTE_ARRAY(pm_lock_new)
TYPE_PRIMITIVE_NULL(pm_lock_del)
TYPE_PRIMITIVE_NULL(pm_lock_acquire);
TYPE_PRIMITIVE_NULL(pm_lock_release);
TYPE_PRIMITIVE_NULL(pm_locks_dump);

}  // namespace toit::compiler
}  // namespace toit
