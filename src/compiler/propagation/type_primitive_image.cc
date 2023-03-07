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

MODULE_TYPES(image, MODULE_IMAGE)

TYPE_PRIMITIVE_ANY(current_id)
TYPE_PRIMITIVE_ANY(writer_create)
TYPE_PRIMITIVE_ANY(writer_write)
TYPE_PRIMITIVE_ANY(writer_commit)
TYPE_PRIMITIVE_ANY(writer_close)

}  // namespace toit::compiler
}  // namespace toit
