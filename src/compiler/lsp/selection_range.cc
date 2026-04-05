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

#include "selection_range.h"

#include <algorithm>

namespace toit {
namespace compiler {

/// An AST visitor that collects all ranges containing a target position.
///
/// For each node visited, both `full_range()` and `selection_range()` are
/// considered. Duplicate and invalid ranges are filtered out. The result
/// is sorted from innermost (smallest) to outermost (largest).
class SelectionRangeCollector : public ast::TraversingVisitor {
 public:
  explicit SelectionRangeCollector(Source::Range target) : target_(target) {}

  /// Walks the AST unit and returns the collected ranges, sorted innermost first.
  std::vector<Source::Range> collect(ast::Unit* unit) {
    ranges_.clear();
    unit->accept(this);
    return finalize();
  }

 private:
  Source::Range target_;
  std::vector<Source::Range> ranges_;

  /// If the node's range contains the target, records it.
  void check_and_add(ast::Node* node) {
    auto full = node->full_range();
    if (full.is_valid() && full.contains(target_)) {
      ranges_.push_back(full);
    }
    auto selection = node->selection_range();
    if (selection.is_valid() && selection.contains(target_) && selection != full) {
      ranges_.push_back(selection);
    }
  }

  /// Sorts and deduplicates the collected ranges.
  std::vector<Source::Range> finalize() {
    // Sort by length ascending (innermost first).
    std::sort(ranges_.begin(), ranges_.end(),
              [](const Source::Range& a, const Source::Range& b) {
                if (a.length() != b.length()) return a.length() < b.length();
                // For equal lengths, prefer the one starting later (more specific).
                return b.is_before(a);
              });
    // Remove duplicates.
    auto last = std::unique(ranges_.begin(), ranges_.end());
    ranges_.erase(last, ranges_.end());
    return std::move(ranges_);
  }

  // --- Visitor overrides ---
  // Each override calls check_and_add before recursing into children.

#define SELECTION_RANGE_OVERRIDE(name)                                \
  void visit_##name(ast::name* node) override {                       \
    check_and_add(node);                                              \
    TraversingVisitor::visit_##name(node);                            \
  }

  SELECTION_RANGE_OVERRIDE(Unit)
  SELECTION_RANGE_OVERRIDE(Import)
  SELECTION_RANGE_OVERRIDE(Export)
  SELECTION_RANGE_OVERRIDE(Class)
  SELECTION_RANGE_OVERRIDE(Declaration)
  SELECTION_RANGE_OVERRIDE(Field)
  SELECTION_RANGE_OVERRIDE(Method)
  SELECTION_RANGE_OVERRIDE(Expression)
  SELECTION_RANGE_OVERRIDE(Error)
  SELECTION_RANGE_OVERRIDE(NamedArgument)
  SELECTION_RANGE_OVERRIDE(BreakContinue)
  SELECTION_RANGE_OVERRIDE(Parenthesis)
  SELECTION_RANGE_OVERRIDE(Block)
  SELECTION_RANGE_OVERRIDE(Lambda)
  SELECTION_RANGE_OVERRIDE(Sequence)
  SELECTION_RANGE_OVERRIDE(DeclarationLocal)
  SELECTION_RANGE_OVERRIDE(If)
  SELECTION_RANGE_OVERRIDE(While)
  SELECTION_RANGE_OVERRIDE(For)
  SELECTION_RANGE_OVERRIDE(TryFinally)
  SELECTION_RANGE_OVERRIDE(Return)
  SELECTION_RANGE_OVERRIDE(Unary)
  SELECTION_RANGE_OVERRIDE(Binary)
  SELECTION_RANGE_OVERRIDE(Call)
  SELECTION_RANGE_OVERRIDE(Dot)
  SELECTION_RANGE_OVERRIDE(Index)
  SELECTION_RANGE_OVERRIDE(IndexSlice)
  SELECTION_RANGE_OVERRIDE(Identifier)
  SELECTION_RANGE_OVERRIDE(Nullable)
  SELECTION_RANGE_OVERRIDE(LspSelection)
  SELECTION_RANGE_OVERRIDE(Parameter)
  SELECTION_RANGE_OVERRIDE(LiteralNull)
  SELECTION_RANGE_OVERRIDE(LiteralUndefined)
  SELECTION_RANGE_OVERRIDE(LiteralBoolean)
  SELECTION_RANGE_OVERRIDE(LiteralInteger)
  SELECTION_RANGE_OVERRIDE(LiteralCharacter)
  SELECTION_RANGE_OVERRIDE(LiteralString)
  SELECTION_RANGE_OVERRIDE(LiteralStringInterpolation)
  SELECTION_RANGE_OVERRIDE(LiteralFloat)
  SELECTION_RANGE_OVERRIDE(LiteralList)
  SELECTION_RANGE_OVERRIDE(LiteralByteArray)
  SELECTION_RANGE_OVERRIDE(LiteralSet)
  SELECTION_RANGE_OVERRIDE(LiteralMap)
  SELECTION_RANGE_OVERRIDE(ToitdocReference)

#undef SELECTION_RANGE_OVERRIDE
};

void emit_selection_ranges(ast::Unit* unit,
                           const std::vector<std::pair<int, int>>& positions,
                           SourceManager* source_manager,
                           LspProtocol* protocol) {
  auto* source = unit->source();
  ASSERT(source != null);

  auto* selection_range_protocol = protocol->selection_range();

  for (const auto& pos : positions) {
    int line = pos.first;    // 1-based.
    int column = pos.second; // 1-based.

    auto source_position = SourceManager::line_column_to_position(source, line, column);
    Source::Range target(source_position);

    SelectionRangeCollector collector(target);
    auto ranges = collector.collect(unit);

    selection_range_protocol->emit_range_count(static_cast<int>(ranges.size()));
    for (const auto& range : ranges) {
      auto lsp_range = range_to_lsp_range(range, source_manager);
      selection_range_protocol->emit_range(lsp_range);
    }
  }
}

} // namespace compiler
} // namespace toit
