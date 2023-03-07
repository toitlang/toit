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

MODULE_TYPES(tls, MODULE_TLS)

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(deinit)
TYPE_PRIMITIVE_ANY(init_socket)
TYPE_PRIMITIVE_ANY(create)
TYPE_PRIMITIVE_ANY(set_outgoing)
TYPE_PRIMITIVE_ANY(get_outgoing_fullness)
TYPE_PRIMITIVE_ANY(set_incoming)
TYPE_PRIMITIVE_ANY(get_incoming_from)
TYPE_PRIMITIVE_ANY(handshake)
TYPE_PRIMITIVE_ANY(close)
TYPE_PRIMITIVE_ANY(close_write)
TYPE_PRIMITIVE_ANY(read)
TYPE_PRIMITIVE_ANY(write)
TYPE_PRIMITIVE_ANY(add_root_certificate)
TYPE_PRIMITIVE_ANY(add_certificate)
TYPE_PRIMITIVE_ANY(error)
TYPE_PRIMITIVE_ANY(get_session)
TYPE_PRIMITIVE_ANY(set_session)
TYPE_PRIMITIVE_ANY(get_internals)

}  // namespace toit::compiler
}  // namespace toit
