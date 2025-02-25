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

MODULE_TYPES(encoding, MODULE_ENCODING)

TYPE_PRIMITIVE_ANY(base64_encode)
TYPE_PRIMITIVE_ANY(base64_decode)
TYPE_PRIMITIVE_ANY(tison_decode)

TYPE_PRIMITIVE(tison_encode) {
  result.add_byte_array(program);
  failure.add_string(program);
  failure.add_array(program);
}

}  // namespace toit::compiler
}  // namespace toit
