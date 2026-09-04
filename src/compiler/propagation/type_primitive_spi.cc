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

MODULE_TYPES(spi, MODULE_SPI)

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(target_init)
TYPE_PRIMITIVE_ANY(target_create)
TYPE_PRIMITIVE_ANY(target_close)
TYPE_PRIMITIVE_ANY(target_transfer_start)
TYPE_PRIMITIVE_ANY(target_transfer_finish)
TYPE_PRIMITIVE_ANY(buffer_target_create)
TYPE_PRIMITIVE_ANY(buffer_target_arm)
TYPE_PRIMITIVE_ANY(buffer_target_close)
TYPE_PRIMITIVE_ANY(buffer_target_get)
TYPE_PRIMITIVE_ANY(buffer_target_set)
TYPE_PRIMITIVE_ANY(buffer_target_read)
TYPE_PRIMITIVE_ANY(buffer_target_write)
TYPE_PRIMITIVE_ANY(buffer_target_receive)
TYPE_PRIMITIVE_ANY(buffer_target_dropped_receive_count)
TYPE_PRIMITIVE_ANY(close)
TYPE_PRIMITIVE_ANY(device)
TYPE_PRIMITIVE_ANY(device_close)
TYPE_PRIMITIVE_ANY(transfer)
TYPE_PRIMITIVE_ANY(acquire_bus)
TYPE_PRIMITIVE_ANY(release_bus)

}  // namespace toit::compiler
}  // namespace toit
