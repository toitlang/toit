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

#include "format_layout.h"
#include "format_repair.h"
#include "format_syntax.h"

namespace toit {
namespace compiler {

class Source;

namespace ast {
class Expression;
}

struct LoweredExpression {
  Layout* layout;
  ExpressionSpan span;
};

// Lowers the expression into logical text and legal line-break choices.
// Source parentheses and source newlines are deliberately not preferences and
// therefore do not enter the returned Layout. Required parentheses are
// recorded in `syntax` and materialized only after select_layout has run.
//
// This first slice supports atoms, unary/binary expressions, and ordinary
// calls. Keeping the entry point narrow makes the architectural invariant
// reviewable before suites, collections, and trivia add more layout shapes.
LoweredExpression lower_expression(ast::Expression* expression, Source* source,
                                   LayoutBuilder* layouts,
                                   LogicalOperatorBindings* bindings,
                                   SyntaxProtection* syntax,
                                   const FormatStyle& style = FormatStyle());

} // namespace compiler
} // namespace toit
