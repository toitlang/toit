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

#include "format_syntax.h"

#include "../top.h"

namespace toit {
namespace compiler {

void SyntaxProtection::require_parentheses(ExpressionSpan expression) {
  ASSERT(expression.start.is_valid());
  ASSERT(expression.end.is_valid());
  requirements_.push_back({expression, Requirement::ALWAYS, LayoutMarker()});
}

void SyntaxProtection::require_parentheses_unless_break_between(
    ExpressionSpan expression, LayoutMarker delimiter_start) {
  ASSERT(expression.start.is_valid());
  ASSERT(expression.end.is_valid());
  ASSERT(delimiter_start.is_valid());
  requirements_.push_back(
      {expression, Requirement::UNLESS_BREAK_BETWEEN, delimiter_start});
}

PlanInsertions SyntaxProtection::resolve(const FinalPlan& plan) const {
  PlanInsertions result;
  for (const Requirement& requirement : requirements_) {
    // Validate both insertion boundaries even for an unconditional rule. A
    // stale lowering marker should fail here rather than disappear silently
    // during rendering.
    plan.line_of(requirement.expression.start);
    plan.line_of(requirement.expression.end);
    bool needed;
    switch (requirement.condition) {
    case Requirement::ALWAYS:
      needed = true;
      break;
    case Requirement::UNLESS_BREAK_BETWEEN:
      needed = !plan.has_break_between(requirement.delimiter_start,
                                       requirement.expression.start);
      break;
    default:
      UNREACHABLE();
    }
    if (!needed) continue;

    // Both characters are inserted before their boundary marker. With nested
    // spans, marker order supplies the right nesting automatically:
    // outer-start, inner-start, inner-end, outer-end becomes `((x))`.
    result.insert_before(requirement.expression.start, "(");
    result.insert_before(requirement.expression.end, ")");
  }
  return result;
}

} // namespace compiler
} // namespace toit
