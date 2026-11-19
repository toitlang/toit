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

TYPE_PRIMITIVE_BYTE_ARRAY(init)
TYPE_PRIMITIVE_NULL(deinit)
TYPE_PRIMITIVE_NULL(init_socket)
TYPE_PRIMITIVE_BYTE_ARRAY(create)
TYPE_PRIMITIVE_BYTE_ARRAY(take_outgoing)
TYPE_PRIMITIVE_NULL(set_incoming)
TYPE_PRIMITIVE_NULL(handshake)
TYPE_PRIMITIVE_NULL(close)

TYPE_PRIMITIVE(close_write) {
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE(read) {
  result.add_byte_array(program);
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_SMI(write)
TYPE_PRIMITIVE_NULL(add_root_certificate)
TYPE_PRIMITIVE_INT(add_global_root_certificate)
TYPE_PRIMITIVE_NULL(use_system_trusted_root_certificates)
TYPE_PRIMITIVE_NULL(add_certificate)

TYPE_PRIMITIVE(error) {
  failure.add_string(program);
}

TYPE_PRIMITIVE(get_internals) {
  result.add_array(program);
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_NULL(get_random)
TYPE_PRIMITIVE_BYTE_ARRAY(token_acquire)
TYPE_PRIMITIVE_NULL(token_release)

}  // namespace toit::compiler
}  // namespace toit
