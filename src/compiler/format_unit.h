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
#include "scanner.h"
#include "sources.h"

namespace toit {
namespace compiler {

// Formats a complete compilation unit. Unsupported syntax or trivia returns
// false; callers must then leave the destination untouched.
bool format_unit(ast::Unit* unit,
                 Source* source,
                 List<Scanner::Comment> comments,
                 std::string* result,
                 const FormatStyle& style = FormatStyle(),
                 const FormatExpressionOptions& expression_options =
                     FormatExpressionOptions());

} // namespace compiler
} // namespace toit
