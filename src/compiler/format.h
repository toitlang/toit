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

#pragma once

#include "scanner.h"
#include "list.h"

namespace toit {
namespace compiler {

namespace ast {
class Unit;
}

struct FormatOptions {
  // When true, forces every expression encountered as a statement to be
  // emitted in its always-flat form (target + canonical spacing + paren
  // insertion where the AST requires it). Used exclusively by CI to
  // validate paren correctness; never the default.
  bool force_flat = false;
};

uint8* format_unit(ast::Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size,
                   FormatOptions options = {});

} // namespace toit::compiler
} // namespace toit
