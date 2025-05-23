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

MODULE_TYPES(i2s, MODULE_I2S)

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(create)
TYPE_PRIMITIVE_ANY(configure)
TYPE_PRIMITIVE_ANY(start)
TYPE_PRIMITIVE_ANY(stop)
TYPE_PRIMITIVE_ANY(preload)
TYPE_PRIMITIVE_ANY(close)
TYPE_PRIMITIVE_ANY(write)
TYPE_PRIMITIVE_ANY(read_to_buffer)
TYPE_PRIMITIVE_INT(errors_underrun)
TYPE_PRIMITIVE_INT(errors_overrun)

}  // namespace toit::compiler
}  // namespace toit
