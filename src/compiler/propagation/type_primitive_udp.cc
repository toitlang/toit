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

MODULE_TYPES(udp, MODULE_UDP)

TYPE_PRIMITIVE_BYTE_ARRAY(init)
TYPE_PRIMITIVE_BYTE_ARRAY(create_socket)
TYPE_PRIMITIVE_BYTE_ARRAY(bind)
TYPE_PRIMITIVE_NULL(bind_socket)

TYPE_PRIMITIVE(connect) {
  result.add_byte_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE(receive) {
  result.add_array(program);
  result.add_byte_array(program);
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_SMI(send)

TYPE_PRIMITIVE(get_option) {
  result.add_byte_array(program);
  result.add_string(program);
  result.add_bool(program);
  result.add_smi(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_NULL(set_option)
TYPE_PRIMITIVE_SMI(error_number)
TYPE_PRIMITIVE_NULL(close)

TYPE_PRIMITIVE(gc) {
  result.add_bool(program);
  result.add_null(program);
  failure.add_string(program);
}

}  // namespace toit::compiler
}  // namespace toit
