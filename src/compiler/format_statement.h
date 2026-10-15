// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.

#pragma once

#include <string>

#include "ast.h"
#include "format_expression.h"
#include "format_output.h"
#include "format_source.h"
#include "sources.h"

namespace toit {
namespace compiler {

// Formats a statement sequence at the supplied absolute indentation. Returns
// false when the sequence contains an AST kind outside the implemented slice.
bool format_sequence(ast::Sequence* sequence,
                     Source* source,
                     int indentation,
                     std::string* result,
                     const FormatStyle& style = FormatStyle(),
                     const FormatExpressionOptions& expression_options =
                         FormatExpressionOptions(),
                     FormatCommentState* comments = null);

} // namespace compiler
} // namespace toit
