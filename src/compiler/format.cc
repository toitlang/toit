// Copyright (C) 2025 Toit contributors.
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

#include <string>

#include "../top.h"
#include "format.h"
#include "ast.h"

namespace toit {
namespace compiler {

using namespace ast;

/// Formats the given unit and returns the formatted version.
/// The returned string must be freed.
uint8* format_unit(Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size) {
  // TODO.
}

} // namespace toit::compiler
} // namespace toit
