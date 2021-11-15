// Copyright (C) 2020 Toitware ApS.
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

#include "../ir.h"
#include "../map.h"
#include "../set.h"

namespace toit {
namespace compiler {

/// Optimizes type-checks when the expression type is known.
///
/// Removes as-checks.
/// Replaces is-checks with a sequence of the expression followed by true/false.
ir::Expression* optimize_typecheck(ir::Typecheck* node, ir::Class* holder, ir::Method* method);

} // namespace toit::compiler
} // namespace toit
