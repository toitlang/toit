// Copyright (C) 2026 Toit contributors.
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

#include "format_expression.h"
#include "format_trivia.h"

namespace toit {
namespace compiler {

namespace ast {
class Sequence;
}

// Lowers all statements and comments in [source_from, source_to). Explicit
// source bounds are important: a trailing comment is part of the body even
// though no AST node owns it. Nested statement sequences derive smaller bounds
// from their colon and next sibling, which makes indentation ownership
// structural instead of heuristic.
//
// Every comment fully contained in the region must be consumed exactly once.
// Inline block comments become part of a semantic statement/expression;
// own-line comments become statement-like layouts; a line containing `//`
// becomes a verbatim barrier.
Layout* lower_body(ast::Sequence* body,
                   Source* source,
                   int source_from,
                   int source_to,
                   LayoutBuilder* layouts,
                   LogicalOperatorBindings* bindings,
                   SyntaxProtection* syntax,
                   TriviaLowering* trivia,
                   const FormatStyle& style = FormatStyle());

} // namespace compiler
} // namespace toit
