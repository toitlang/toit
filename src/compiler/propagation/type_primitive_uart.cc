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

MODULE_TYPES(uart, MODULE_UART)

TYPE_PRIMITIVE_BYTE_ARRAY(init)
TYPE_PRIMITIVE_BYTE_ARRAY(create)
TYPE_PRIMITIVE_BYTE_ARRAY(create_path)
TYPE_PRIMITIVE_NULL(close)
TYPE_PRIMITIVE_INT(get_baud_rate)
TYPE_PRIMITIVE_NULL(set_baud_rate)
TYPE_PRIMITIVE_INT(write)

TYPE_PRIMITIVE(read) {
  result.add_byte_array(program);
  result.add_string(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_BOOL(wait_tx)
TYPE_PRIMITIVE_NULL(set_control_flags)
TYPE_PRIMITIVE_SMI(get_control_flags)
TYPE_PRIMITIVE_INT(errors)
TYPE_PRIMITIVE_BYTE_ARRAY(create_console)

}  // namespace toit::compiler
}  // namespace toit
