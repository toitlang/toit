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

#include "format_method.h"

#include "../top.h"

namespace toit {
namespace compiler {

// This file is the only formatter implementation allowed to construct a
// token order different from the AST's ordinary source order.
SelectedPlan select_method_header(const LoweredMethodHeader& header,
                                  int preferred_width) {
  ASSERT(header.source_order_ != null);
  SelectedPlan regular = select_layout(header.source_order_, preferred_width);
  if (header.return_type_ == null ||
      !regular.has_break_between(header.parameters_start_,
                                 header.parameters_end_)) {
    return regular;
  }

  // Generic selection found multiline parameters. Build the one exceptional
  // order directly from semantic header pieces:
  //
  //     foo -> ReturnType
  //         first
  //         second
  //     :
  //
  // No general Layout or SelectedPlan API can express token relocation.
  std::vector<Layout*> forced_parameters;
  for (Layout* parameter : header.parameters_) {
    forced_parameters.push_back(header.layouts_->hardline());
    forced_parameters.push_back(parameter);
  }
  Layout* parameter_lines = header.layouts_->indent(
      header.continuation_step_,
      header.layouts_->concat(std::move(forced_parameters)));
  std::vector<Layout*> reordered = {
      header.name_,
      header.layouts_->text(" -> "),
      header.return_type_,
      parameter_lines,
  };
  if (header.has_colon_) {
    reordered.push_back(header.layouts_->hardline());
    reordered.push_back(header.layouts_->text(":"));
  }
  return select_layout(header.layouts_->concat(std::move(reordered)),
                       preferred_width);
}

} // namespace compiler
} // namespace toit
