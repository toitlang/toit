// Copyright (C) 2024 Toitware ApS.
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

#include "../top.h"

#include "list.h"
#include "scanner.h"

namespace toit {
namespace compiler {

namespace ast {
class Unit;
}

/// Sets the outline ranges of all declarations in the unit.
/// An outline range is the full range of the node, plus the range of its
/// comments. This is used to show the outline of the file an editors.
void set_outline_ranges(ast::Unit* unit, List<Scanner::Comment> comments);

} // namespace toit::compiler
} // namespace toit
