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

#include <vector>

#include "format_expression.h"

namespace toit {
namespace compiler {

namespace ast {
class Method;
}

class MethodHeaderLowering;

// Logical pieces of a parsed method header plus its regular source-order
// layout. The pieces are private so callers cannot assemble or select an
// alternate token order themselves. `select_method_header` is the one normal
// entry point for selecting the regular source-order layout.
class LoweredMethodHeader {
 private:
  LoweredMethodHeader(LayoutBuilder* layouts,
                      Layout* source_order,
                      Layout* name,
                      std::vector<Layout*> parameters,
                      Layout* return_type,
                      bool has_colon,
                      LayoutMarker parameters_start,
                      LayoutMarker parameters_end,
                      int continuation_step)
      : layouts_(layouts)
      , source_order_(source_order)
      , name_(name)
      , parameters_(std::move(parameters))
      , return_type_(return_type)
      , has_colon_(has_colon)
      , parameters_start_(parameters_start)
      , parameters_end_(parameters_end)
      , continuation_step_(continuation_step) {}

  LayoutBuilder* layouts_;
  Layout* source_order_;
  Layout* name_;
  std::vector<Layout*> parameters_;
  Layout* return_type_;
  bool has_colon_;
  LayoutMarker parameters_start_;
  LayoutMarker parameters_end_;
  int continuation_step_;

  friend class MethodHeaderLowering;
  friend SelectedPlan select_method_header(const LoweredMethodHeader&,
                                           int preferred_width);
};

// Lowers actual parsed header components and constructs only their regular,
// source-order layout:
//
//     foo
//         first
//         second -> ReturnType:
//
// Trivia is not part of this prototype slice yet. Keeping the parsed pieces
// separate makes their ownership explicit when trivia is added later.
LoweredMethodHeader lower_method_header(
    ast::Method* method,
    Source* source,
    LayoutBuilder* layouts,
    LogicalOperatorBindings* bindings,
    SyntaxProtection* syntax,
    const FormatStyle& style = FormatStyle());

// Selects the complete method header in source order. Low-level Layout
// selection remains public for focused phase tests, but callers cannot bypass
// this entry point through LoweredMethodHeader.
SelectedPlan select_method_header(const LoweredMethodHeader& header,
                                  int preferred_width);

} // namespace compiler
} // namespace toit
