// Copyright (C) 2019 Toitware ApS.
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

#pragma once

#include "ir.h"

namespace toit {
namespace compiler {

/// Creates stub methods.
///
/// Before a call to this function, methods may be called with different shapes.
/// They may have default-values, or be called with, or without named arguments.
///
/// After this function, each function in the program represents only one shape,
/// which is why methods only use [PlainShape]s after this call.
void add_stub_methods_and_switch_to_plain_shapes(ir::Program* program);

/// Creates interface-stub methods (without any body).
///
/// These can be used for is checks.
void add_interface_stub_methods(ir::Program* program);

} // namespace toit::compiler
} // namespace toit
