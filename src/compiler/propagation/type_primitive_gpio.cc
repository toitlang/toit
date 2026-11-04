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

MODULE_TYPES(gpio, MODULE_GPIO)

TYPE_PRIMITIVE_BYTE_ARRAY(init)
TYPE_PRIMITIVE_BYTE_ARRAY(use)
TYPE_PRIMITIVE_NULL(unuse)
TYPE_PRIMITIVE_NULL(config)
TYPE_PRIMITIVE_SMI(get)
TYPE_PRIMITIVE_NULL(set)
TYPE_PRIMITIVE_SMI(config_interrupt)
TYPE_PRIMITIVE_SMI(last_edge_trigger_timestamp)
TYPE_PRIMITIVE_NULL(set_open_drain)
TYPE_PRIMITIVE_NULL(set_pull)

}  // namespace toit::compiler
}  // namespace toit
