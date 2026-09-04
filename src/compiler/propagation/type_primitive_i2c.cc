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

MODULE_TYPES(i2c, MODULE_I2C)

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(target_init)
TYPE_PRIMITIVE_ANY(target_create)
TYPE_PRIMITIVE_ANY(target_close)
TYPE_PRIMITIVE_ANY(target_receive)
TYPE_PRIMITIVE_ANY(target_write)
TYPE_PRIMITIVE_ANY(target_set_default_response)
TYPE_PRIMITIVE_ANY(target_take_request_count)
TYPE_PRIMITIVE_ANY(target_dropped_receive_count)
TYPE_PRIMITIVE_ANY(register_target_create)
TYPE_PRIMITIVE_ANY(register_target_close)
TYPE_PRIMITIVE_ANY(register_target_get)
TYPE_PRIMITIVE_ANY(register_target_set)
TYPE_PRIMITIVE_ANY(register_target_read)
TYPE_PRIMITIVE_ANY(register_target_write)
TYPE_PRIMITIVE_ANY(register_target_dropped_write_count)
TYPE_PRIMITIVE_ANY(bus_create)
TYPE_PRIMITIVE_ANY(bus_close)
TYPE_PRIMITIVE_ANY(bus_probe)
TYPE_PRIMITIVE_ANY(bus_probe_finish)
TYPE_PRIMITIVE_ANY(bus_abort_controller_operation)
TYPE_PRIMITIVE_ANY(device_create)
TYPE_PRIMITIVE_ANY(device_close)
TYPE_PRIMITIVE_ANY(device_write)
TYPE_PRIMITIVE_ANY(device_write_finish)
TYPE_PRIMITIVE_ANY(device_read)
TYPE_PRIMITIVE_ANY(device_read_finish)
TYPE_PRIMITIVE_ANY(device_write_read)
TYPE_PRIMITIVE_ANY(device_write_read_finish)

}  // namespace toit::compiler
}  // namespace toit
