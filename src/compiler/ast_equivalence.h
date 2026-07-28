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

#include "ast.h"

namespace toit {
namespace compiler {

// Returns true iff the two AST units are semantically equivalent, modulo:
// - source positions (ranges),
// - trivia (comments, whitespace),
// - Parenthesis wrappers (transparent — `(e)` equivalent to `e`).
//
// Intended as the formatter's safety net: the formatted output is parsed
// and compared against the input's AST. A difference means the formatter
// has changed meaning, not just presentation.
//
// On mismatch, `mismatch_a` / `mismatch_b` (when non-null) receive the
// deepest node pair where the difference was detected (either may be
// null when one side is missing a node).
bool ast_equivalent(ast::Unit* a, ast::Unit* b,
                    ast::Node** mismatch_a = null,
                    ast::Node** mismatch_b = null);

} // namespace toit::compiler
} // namespace toit
