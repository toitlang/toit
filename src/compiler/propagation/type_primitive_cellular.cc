// Copyright (C) 2026 Toit contributors.
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

MODULE_TYPES(cellular, MODULE_CELLULAR)

TYPE_PRIMITIVE_BYTE_ARRAY(init)
TYPE_PRIMITIVE_NULL(close)
TYPE_PRIMITIVE_NULL(configure)
TYPE_PRIMITIVE_BYTE_ARRAY(connect)
TYPE_PRIMITIVE_NULL(disconnect)
TYPE_PRIMITIVE_STRING(disconnect_reason)

TYPE_PRIMITIVE(get_ip) {
  result.add_byte_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE(get_cell_info) {
  result.add_array(program);
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

}  // namespace compiler
}  // namespace toit
