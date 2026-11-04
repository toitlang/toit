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

MODULE_TYPES(pipe, MODULE_PIPE)

TYPE_PRIMITIVE_BYTE_ARRAY(init)
TYPE_PRIMITIVE_NULL(close)
TYPE_PRIMITIVE_ARRAY(create_pipe)
TYPE_PRIMITIVE_BYTE_ARRAY(fd_to_pipe)
TYPE_PRIMITIVE_SMI(write)

TYPE_PRIMITIVE(write_result) {
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE(read) {
  result.add_byte_array(program);
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_BYTE_ARRAY(fork)
TYPE_PRIMITIVE_BYTE_ARRAY(fork2)
TYPE_PRIMITIVE_SMI(fd)
TYPE_PRIMITIVE_BOOL(is_a_tty)

}  // namespace toit::compiler
}  // namespace toit
