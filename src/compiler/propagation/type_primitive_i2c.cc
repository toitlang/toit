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

TYPE_PRIMITIVE_BYTE_ARRAY(init)
TYPE_PRIMITIVE_BYTE_ARRAY(target_init)
TYPE_PRIMITIVE_BYTE_ARRAY(target_create)
TYPE_PRIMITIVE_NULL(target_close)

TYPE_PRIMITIVE(target_receive) {
  result.add_byte_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_SMI(target_write)
TYPE_PRIMITIVE_NULL(target_set_write_pending)
TYPE_PRIMITIVE_NULL(target_set_handler_mode)
TYPE_PRIMITIVE_SMI(target_take_request_count)
TYPE_PRIMITIVE_SMI(target_dropped_receive_count)
TYPE_PRIMITIVE_BYTE_ARRAY(register_target_create)
TYPE_PRIMITIVE_NULL(register_target_close)
TYPE_PRIMITIVE_SMI(register_target_get)
TYPE_PRIMITIVE_SMI(register_target_set)
TYPE_PRIMITIVE_BYTE_ARRAY(register_target_read)
TYPE_PRIMITIVE_NULL(register_target_write)
TYPE_PRIMITIVE_SMI(register_target_dropped_write_count)
TYPE_PRIMITIVE_BYTE_ARRAY(bus_create)
TYPE_PRIMITIVE_NULL(bus_close)
TYPE_PRIMITIVE_NULL(bus_probe)
TYPE_PRIMITIVE_BOOL(bus_probe_finish)
TYPE_PRIMITIVE_NULL(bus_abort_controller_operation)
TYPE_PRIMITIVE_BYTE_ARRAY(device_create)
TYPE_PRIMITIVE_NULL(device_close)
TYPE_PRIMITIVE_NULL(device_transfer_start)
TYPE_PRIMITIVE_SMI(device_transfer_finish)

}  // namespace toit::compiler
}  // namespace toit
