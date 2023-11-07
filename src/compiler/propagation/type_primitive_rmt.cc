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

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(channel_new)
TYPE_PRIMITIVE_ANY(channel_delete)
TYPE_PRIMITIVE_ANY(config_rx)
TYPE_PRIMITIVE_ANY(config_tx)
TYPE_PRIMITIVE_ANY(get_idle_threshold)
TYPE_PRIMITIVE_ANY(set_idle_threshold)
TYPE_PRIMITIVE_ANY(config_bidirectional_pin)
TYPE_PRIMITIVE_ANY(transmit)
TYPE_PRIMITIVE_ANY(transmit_done)
TYPE_PRIMITIVE_ANY(prepare_receive)
TYPE_PRIMITIVE_ANY(start_receive)
TYPE_PRIMITIVE_ANY(receive)
TYPE_PRIMITIVE_ANY(stop_receive)

}  // namespace toit::compiler
}  // namespace toit
