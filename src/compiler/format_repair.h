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

#include <string>
#include <unordered_map>
#include <vector>

#include "format_layout.h"

namespace toit {
namespace compiler {

namespace ast {
class Binary;
}

class WhitespaceEdits {
 public:
  enum RequestResult {
    ADDED,
    ALREADY_REQUESTED,
    CONFLICT,
  };

  // `rule` is retained for diagnostics. Two rules may request the same state,
  // but contradictory requests are recorded instead of making rule order
  // observable.
  RequestResult request(LayoutGap gap, GapState state, const std::string& rule);

  bool has_conflict() const { return !conflicts_.empty(); }
  const std::vector<std::string>& conflicts() const { return conflicts_; }

 private:
  struct Edit {
    GapState state;
    std::string rule;
  };

  std::unordered_map<int, Edit> edits_;
  std::vector<std::string> conflicts_;

  friend class SelectedPlan;
};

// Layout sites deliberately offered by logical-expression lowering for later
// whitespace repair. The name is intentionally narrow: these are
// policy-neutral handles, but they are not a universal description of every
// binary expression.
class LogicalOperatorBindings {
 public:
  void record(ast::Binary* binary, LayoutGap before_operator,
              LayoutGap after_operator);

 private:
  struct BinaryOperator {
    ast::Binary* binary;
    LayoutGap before_operator;
    LayoutGap after_operator;
  };

  std::vector<BinaryOperator> binary_operators_;

  friend class FormatRepairs;
};

// Matches narrowly chosen AST/layout shapes after generic selection. Each
// named rule contributes whitespace requests to one shared edit set. Rules do
// not abort on conflicts: the caller receives the complete conflict report and
// SelectedPlan::apply rejects it atomically.
class FormatRepairs {
 public:
  static WhitespaceEdits propose(const LogicalOperatorBindings& bindings,
                                 const SelectedPlan& selected);

 private:
  static void propose_mixed_logical_chain(
      const LogicalOperatorBindings& bindings,
      const SelectedPlan& selected,
      WhitespaceEdits* edits);
};

} // namespace compiler
} // namespace toit
