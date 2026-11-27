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

#include "format_layout.h"

namespace toit {
namespace compiler {

// The zero-width boundaries of one expression in a Layout tree. Keeping the
// boundaries separate from the expression's text is what lets lowering omit
// redundant source parentheses without losing the place where canonical ones
// may later be inserted.
//
// For example, the inner expression has the same span in both layouts below:
//
//     foo (bar 1)
//          ^^^^^
//
//     foo
//         bar 1
//         ^^^^^
//
// Only the selected line topology differs.
struct ExpressionSpan {
  LayoutMarker start;
  LayoutMarker end;
};

// Collects grammar constraints while the AST is lowered, then resolves them
// against a frozen plan. This is deliberately not a second pretty-printing
// pass: its separate result contains only single-line insertions at recorded
// boundaries. It cannot move text or reconsider a line break.
class SyntaxProtection {
 public:
  // Use for grammar rules independent of wrapping, such as precedence:
  //
  //     (a + b) * c
  void require_parentheses(ExpressionSpan expression);

  // Use when a newline itself is a delimiter. A nested call argument is the
  // motivating Toit example:
  //
  //     foo (bar 1)       // Same line: parens keep this one argument.
  //
  //     foo
  //         bar 1         // Newline already starts a new argument.
  //
  // `delimiter_start` is normally the end of the outer call's target.
  // Parentheses are inserted unless a selected newline between that marker
  // and the nested expression already acts as the delimiter.
  void require_parentheses_unless_break_between(ExpressionSpan expression,
                                                LayoutMarker delimiter_start);

  PlanInsertions resolve(const FinalPlan& plan) const;

 private:
  struct Requirement {
    enum Condition {
      ALWAYS,
      UNLESS_BREAK_BETWEEN,
    };

    ExpressionSpan expression;
    Condition condition;
    LayoutMarker delimiter_start;
  };

  std::vector<Requirement> requirements_;
};

} // namespace compiler
} // namespace toit
