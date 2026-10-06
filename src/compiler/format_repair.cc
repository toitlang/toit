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

#include "format_repair.h"

#include "../top.h"
#include "ast.h"
#include "token.h"

#include <sstream>
#include <unordered_map>

namespace toit {
namespace compiler {

WhitespaceEdits::RequestResult WhitespaceEdits::request(
    LayoutGap gap,
    GapState state,
    const std::string& rule) {
  ASSERT(gap.is_valid());
  ASSERT(!rule.empty());
  auto existing = edits_.find(gap.id_);
  if (existing == edits_.end()) {
    edits_.insert({gap.id_, {state, rule}});
    return ADDED;
  }
  if (existing->second.state == state) return ALREADY_REQUESTED;

  std::ostringstream message;
  message << "Whitespace rules '" << existing->second.rule << "' and '"
          << rule << "' request different states for gap " << gap.id_;
  conflicts_.push_back(message.str());
  return CONFLICT;
}

bool SelectedPlan::apply(const WhitespaceEdits& edits) {
  if (edits.has_conflict()) return false;
  for (const auto& entry : edits.edits_) {
    LayoutGap gap(entry.first);
    ASSERT(can_select(gap, entry.second.state));
    gap_event(gap).newline = entry.second.state == GapState::NEWLINE;
  }
  return true;
}

void LogicalOperatorBindings::record(ast::Binary* binary,
                                     LayoutGap before_operator,
                                     LayoutGap after_operator) {
  ASSERT(binary != null);
  ASSERT(before_operator.is_valid());
  ASSERT(after_operator.is_valid());
  binary_operators_.push_back({binary, before_operator, after_operator});
}

WhitespaceEdits FormatRepairs::propose(
    const LogicalOperatorBindings& bindings,
    const SelectedPlan& selected) {
  WhitespaceEdits edits;
  propose_mixed_logical_chain(bindings, selected, &edits);
  return edits;
}

void FormatRepairs::propose_mixed_logical_chain(
    const LogicalOperatorBindings& bindings,
    const SelectedPlan& selected,
    WhitespaceEdits* edits) {
  ASSERT(edits != null);
  std::unordered_map<ast::Binary*,
                     const LogicalOperatorBindings::BinaryOperator*>
      handles;
  for (const LogicalOperatorBindings::BinaryOperator& binding :
       bindings.binary_operators_) {
    handles[binding.binary] = &binding;
  }

  for (const LogicalOperatorBindings::BinaryOperator& candidate :
       bindings.binary_operators_) {
    ast::Binary* binary = candidate.binary;

    // The generic rule puts a broken operator at the start of its continuation:
    //
    //     foo
    //         or bar
    //             and gee
    //
    // For exactly `or` with an `and` on its right, this repair treats the
    // tighter expression as a visual unit:
    //
    //     foo or
    //         bar and gee
    //
    // If the shape or selected break does not match, the generic output
    // remains unchanged and correct.
    if (binary->kind() != Token::LOGICAL_OR) continue;
    ast::Expression* right = binary->right();
    while (right->is_Parenthesis()) {
      right = right->as_Parenthesis()->expression();
    }
    if (!right->is_Binary() ||
        right->as_Binary()->kind() != Token::LOGICAL_AND) continue;
    if (!selected.is_selected(candidate.before_operator, GapState::NEWLINE)) {
      continue;
    }

    ASSERT(selected.can_select(candidate.before_operator, GapState::FLAT));
    ASSERT(selected.can_select(candidate.after_operator, GapState::NEWLINE));
    edits->request(candidate.before_operator, GapState::FLAT,
                   "mixed-logical-chain");
    edits->request(candidate.after_operator, GapState::NEWLINE,
                   "mixed-logical-chain");

    // Moving the break after `or` changes the local width pressure that made
    // the nested `and` break. Explicitly flatten both of its gaps so the rule
    // produces the complete example above without rerunning generic selection.
    // The preferred width is soft, so this local choice cannot create an
    // invalid result merely because it extends past that preference.
    ast::Binary* inner_and = right->as_Binary();
    auto found = handles.find(inner_and);
    ASSERT(found != handles.end());
    if (found == handles.end()) continue;
    const LogicalOperatorBindings::BinaryOperator* inner = found->second;
    ASSERT(selected.can_select(inner->before_operator, GapState::FLAT));
    ASSERT(selected.can_select(inner->after_operator, GapState::FLAT));
    edits->request(inner->before_operator, GapState::FLAT,
                   "mixed-logical-chain");
    edits->request(inner->after_operator, GapState::FLAT,
                   "mixed-logical-chain");
  }
}

} // namespace compiler
} // namespace toit
