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

MODULE_TYPES(rmt, MODULE_RMT)

TYPE_PRIMITIVE_INT(bytes_per_memory_block)
TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(channel_new)
TYPE_PRIMITIVE_ANY(channel_delete)
TYPE_PRIMITIVE_NULL(enable)
TYPE_PRIMITIVE_NULL(disable)
TYPE_PRIMITIVE_ANY(transmit)
TYPE_PRIMITIVE_ANY(transmit_with_encoder)
TYPE_PRIMITIVE_BOOL(is_transmit_done)
TYPE_PRIMITIVE_BOOL(start_receive)
TYPE_PRIMITIVE_ANY(receive)
TYPE_PRIMITIVE_NULL(apply_carrier)
TYPE_PRIMITIVE_ANY(sync_manager_new)
TYPE_PRIMITIVE_NULL(sync_manager_delete)
TYPE_PRIMITIVE_NULL(sync_manager_reset)
TYPE_PRIMITIVE_ANY(encoder_new)
TYPE_PRIMITIVE_NULL(encoder_delete)

}  // namespace toit::compiler
}  // namespace toit
