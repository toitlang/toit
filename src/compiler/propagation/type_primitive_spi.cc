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

MODULE_TYPES(spi, MODULE_SPI)

TYPE_PRIMITIVE_BYTE_ARRAY(init)
TYPE_PRIMITIVE_BYTE_ARRAY(target_init)
TYPE_PRIMITIVE_BYTE_ARRAY(target_create)
TYPE_PRIMITIVE_NULL(target_close)
TYPE_PRIMITIVE_NULL(target_transfer_start)

TYPE_PRIMITIVE(target_transfer_finish) {
  result.add_bool(program);
  result.add_smi(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_BYTE_ARRAY(buffer_target_create)
TYPE_PRIMITIVE_NULL(buffer_target_arm)

TYPE_PRIMITIVE(buffer_target_close) {
  result.add_bool(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_SMI(buffer_target_get)
TYPE_PRIMITIVE_SMI(buffer_target_set)
TYPE_PRIMITIVE_NULL(buffer_target_read)
TYPE_PRIMITIVE_NULL(buffer_target_write)
TYPE_PRIMITIVE_SMI(buffer_target_receive)
TYPE_PRIMITIVE_SMI(buffer_target_dropped_receive_count)
TYPE_PRIMITIVE_NULL(close)
TYPE_PRIMITIVE_BYTE_ARRAY(device)
TYPE_PRIMITIVE_NULL(device_close)
TYPE_PRIMITIVE_NULL(transfer_start)
TYPE_PRIMITIVE_BOOL(transfer_finish)
TYPE_PRIMITIVE_BOOL(transfer_abort)
TYPE_PRIMITIVE_BOOL(acquire_bus)
TYPE_PRIMITIVE_NULL(release_bus)

}  // namespace toit::compiler
}  // namespace toit
