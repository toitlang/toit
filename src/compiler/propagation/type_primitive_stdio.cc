// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(stdio, MODULE_STDIO)

TYPE_PRIMITIVE_BYTE_ARRAY(stdin_init)
TYPE_PRIMITIVE_BYTE_ARRAY(stdin_open)

TYPE_PRIMITIVE(stdin_read) {
  result.add_byte_array(program);
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

}  // namespace toit::compiler
}  // namespace toit
