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

MODULE_TYPES(programs_registry, MODULE_PROGRAMS_REGISTRY)

TYPE_PRIMITIVE_SMI(next_group_id)
TYPE_PRIMITIVE_BOOL(is_running)
TYPE_PRIMITIVE_BOOL(kill)
TYPE_PRIMITIVE_ARRAY(bundled_images)
TYPE_PRIMITIVE_BYTE_ARRAY(assets)
TYPE_PRIMITIVE_BYTE_ARRAY(config)

TYPE_PRIMITIVE(spawn) {
  result.add_smi(program);
  failure.add_string(program);
  failure.add_array(program);
}

}  // namespace toit::compiler
}  // namespace toit
