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

TYPE_PRIMITIVE(next) {
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_SMI(info)
TYPE_PRIMITIVE_SMI(erase)
TYPE_PRIMITIVE_SMI(get_size)
TYPE_PRIMITIVE_BYTE_ARRAY(get_header_page)
TYPE_PRIMITIVE_BYTE_ARRAY(get_all_pages)
TYPE_PRIMITIVE_NULL(write_non_header_pages)
TYPE_PRIMITIVE_NULL(reserve_hole)
TYPE_PRIMITIVE_BOOL(cancel_reservation)
TYPE_PRIMITIVE_NULL(allocate)
TYPE_PRIMITIVE_BOOL(erase_flash_registry)
TYPE_PRIMITIVE_NULL(grant_access)
TYPE_PRIMITIVE_BOOL(is_accessed)
TYPE_PRIMITIVE_NULL(revoke_access)
TYPE_PRIMITIVE_ARRAY(partition_find)
TYPE_PRIMITIVE_BYTE_ARRAY(region_open)
TYPE_PRIMITIVE_NULL(region_close)
TYPE_PRIMITIVE_NULL(region_read)
TYPE_PRIMITIVE_NULL(region_write)
TYPE_PRIMITIVE_BOOL(region_is_erased)
TYPE_PRIMITIVE_NULL(region_erase)

}  // namespace toit::compiler
}  // namespace toit
