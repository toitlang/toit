// Copyright (C) 2024 Toitware ApS.
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

MODULE_TYPES(gpio_linux, MODULE_GPIO_LINUX)

TYPE_PRIMITIVE_ANY(list_chips)
TYPE_PRIMITIVE_ANY(chip_init)
TYPE_PRIMITIVE_ANY(chip_new)
TYPE_PRIMITIVE_ANY(chip_close)
TYPE_PRIMITIVE_ANY(chip_info)
TYPE_PRIMITIVE_ANY(chip_pin_info)
TYPE_PRIMITIVE_ANY(chip_pin_offset_for_name)
TYPE_PRIMITIVE_ANY(pin_init)
TYPE_PRIMITIVE_ANY(pin_new)
TYPE_PRIMITIVE_ANY(pin_close)
TYPE_PRIMITIVE_ANY(pin_configure)
TYPE_PRIMITIVE_ANY(pin_get)
TYPE_PRIMITIVE_ANY(pin_set)
TYPE_PRIMITIVE_ANY(pin_set_open_drain)

}  // namespace toit::compiler
}  // namespace toit
