// Copyright (C) 2026 Toit contributors.
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

MODULE_TYPES(ec618, MODULE_EC618)

TYPE_PRIMITIVE_INT(print_uart_id)
TYPE_PRIMITIVE_INT(slot_active)
TYPE_PRIMITIVE_ANY(slot_inactive_erase)
TYPE_PRIMITIVE_ANY(slot_inactive_write)
TYPE_PRIMITIVE_ANY(slot_reloc_begin)
TYPE_PRIMITIVE_ANY(slot_reloc_end)
TYPE_PRIMITIVE_ANY(slot_stage_and_reset)
TYPE_PRIMITIVE_ANY(slot_stage)
TYPE_PRIMITIVE_ANY(slot_mark_valid)
TYPE_PRIMITIVE_ANY(slot_mark_invalid_and_reset)
TYPE_PRIMITIVE_BOOL(slot_trial)
TYPE_PRIMITIVE_ANY(slot_program_mode)
TYPE_PRIMITIVE_INT(modem_set_function)

}  // namespace compiler
}  // namespace toit
