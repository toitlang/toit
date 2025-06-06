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

MODULE_TYPES(espnow, MODULE_ESPNOW)

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(create)
TYPE_PRIMITIVE_ANY(close)
TYPE_PRIMITIVE_ANY(send)
TYPE_PRIMITIVE_BOOL(send_succeeded)
TYPE_PRIMITIVE_ANY(receive)
TYPE_PRIMITIVE_ANY(add_peer)
TYPE_PRIMITIVE_NULL(remove_peer)

}  // namespace toit::compiler
}  // namespace toit
