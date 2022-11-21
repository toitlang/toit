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

MODULE_TYPES(pipe, MODULE_PIPE)

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(close)
TYPE_PRIMITIVE_ANY(create_pipe)
TYPE_PRIMITIVE_ANY(fd_to_pipe)
TYPE_PRIMITIVE_ANY(write)
TYPE_PRIMITIVE_ANY(read)
TYPE_PRIMITIVE_ANY(fork)
TYPE_PRIMITIVE_ANY(fd)
TYPE_PRIMITIVE_ANY(is_a_tty)

}  // namespace toit::compiler
}  // namespace toit
