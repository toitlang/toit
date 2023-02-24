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

MODULE_TYPES(flash, MODULE_FLASH_REGISTRY)

TYPE_PRIMITIVE_ANY(next)
TYPE_PRIMITIVE_ANY(info)
TYPE_PRIMITIVE_ANY(erase)
TYPE_PRIMITIVE_ANY(get_id)
TYPE_PRIMITIVE_ANY(get_size)
TYPE_PRIMITIVE_ANY(get_type)
TYPE_PRIMITIVE_ANY(get_metadata)
TYPE_PRIMITIVE_ANY(reserve_hole)
TYPE_PRIMITIVE_ANY(cancel_reservation)
TYPE_PRIMITIVE_ANY(allocate)
TYPE_PRIMITIVE_ANY(erase_flash_registry)
TYPE_PRIMITIVE_ANY(grant_access)
TYPE_PRIMITIVE_ANY(revoke_access)
TYPE_PRIMITIVE_ANY(region_open)
TYPE_PRIMITIVE_ANY(region_close)
TYPE_PRIMITIVE_ANY(region_read)
TYPE_PRIMITIVE_ANY(region_write)
TYPE_PRIMITIVE_ANY(region_erase)

}  // namespace toit::compiler
}  // namespace toit
