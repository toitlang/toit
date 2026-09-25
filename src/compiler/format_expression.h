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
#include "format_output.h"
#include "sources.h"

namespace toit {
namespace compiler {

// Produces the canonical one-line spelling for an expression. Returns false
// when the expression kind is not implemented or inherently spans lines.
bool format_expression_flat(ast::Expression* expression,
                            Source* source,
                            std::string* result);

// Formats one expression directly from its AST. Returns false for expression
// kinds not implemented by the current review slice.
bool format_expression(ast::Expression* expression,
                       Source* source,
                       int base_indentation,
                       FormatOutput* result,
                       const FormatStyle& style = FormatStyle());

} // namespace compiler
} // namespace toit
