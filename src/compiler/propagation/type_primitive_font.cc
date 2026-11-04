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

MODULE_TYPES(font, MODULE_FONT)

TYPE_PRIMITIVE(get_font) {
  result.add_byte_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_SMI(get_text_size)
TYPE_PRIMITIVE_BYTE_ARRAY(get_nonbuiltin)
TYPE_PRIMITIVE_NULL(delete_font)
TYPE_PRIMITIVE_BOOL(contains)

}  // namespace toit::compiler
}  // namespace toit
