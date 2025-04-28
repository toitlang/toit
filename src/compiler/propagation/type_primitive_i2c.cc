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

MODULE_TYPES(i2c, MODULE_I2C)

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(bus_create)
TYPE_PRIMITIVE_ANY(bus_close)
TYPE_PRIMITIVE_ANY(bus_probe)
TYPE_PRIMITIVE_ANY(bus_reset)
TYPE_PRIMITIVE_ANY(device_create)
TYPE_PRIMITIVE_ANY(device_close)
TYPE_PRIMITIVE_ANY(device_write)
TYPE_PRIMITIVE_ANY(device_read)
TYPE_PRIMITIVE_ANY(device_write_read)

}  // namespace toit::compiler
}  // namespace toit
