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

TYPE_PRIMITIVE_BYTE_ARRAY(init)
TYPE_PRIMITIVE_BYTE_ARRAY(create)
TYPE_PRIMITIVE_NULL(configure)
TYPE_PRIMITIVE_NULL(configure_buffered)
TYPE_PRIMITIVE_NULL(start)
TYPE_PRIMITIVE_NULL(stop)
TYPE_PRIMITIVE_SMI(preload)
TYPE_PRIMITIVE_NULL(close)
TYPE_PRIMITIVE_SMI(write)
TYPE_PRIMITIVE_SMI(read_to_buffer)
TYPE_PRIMITIVE_INT(errors_underrun)
TYPE_PRIMITIVE_INT(errors_overrun)

}  // namespace toit::compiler
}  // namespace toit
