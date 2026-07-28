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

#include "format_layout.h"
#include "list.h"
#include "scanner.h"

namespace toit {
namespace compiler {

namespace ast {
class Unit;
}

// Formats the unit: attaches comments and blank lines to AST nodes, lowers the
// AST to a tree of legal layout alternatives, then chooses and renders those
// alternatives.
// The returned buffer is malloced; the caller takes ownership.
uint8* format_unit(ast::Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size,
                   bool* all_trivia_emitted,
                   const FormatStyle& style = {});

} // namespace toit::compiler
} // namespace toit
