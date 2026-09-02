// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.

#pragma once

#include "ast.h"
#include "format_expression.h"
#include "format_output.h"
#include "sources.h"

namespace toit {
namespace compiler {

// Formats a method header, including its body-introducing colon when present.
// The body itself is deliberately outside this review slice. Returns false if
// a parameter or type contains an expression not yet supported by the printer.
bool format_method_header(ast::Method* method,
                          Source* source,
                          int base_indentation,
                          FormatOutput* result,
                          const FormatStyle& style = FormatStyle(),
                          const FormatExpressionOptions& expression_options =
                              FormatExpressionOptions());

} // namespace compiler
} // namespace toit
