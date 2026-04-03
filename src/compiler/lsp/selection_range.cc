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

#include "../../utils.h"

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
    // Visit the unit node itself (for the file-level range).
    check_and_add(unit);
    // Visit imports and exports (which TraversingVisitor::visit_Unit skips).
    for (int i = 0; i < unit->imports().length(); i++) {
      unit->imports()[i]->accept(this);
    }
    for (int i = 0; i < unit->exports().length(); i++) {
      unit->exports()[i]->accept(this);
    }
    // Visit declarations (same as TraversingVisitor::visit_Unit).
    for (int i = 0; i < unit->declarations().length(); i++) {
      unit->declarations()[i]->accept(this);
    }
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
  // We use a macro for the uniform cases and provide specialized
  // implementations where the base TraversingVisitor skips children
  // we want to visit.

#define SELECTION_RANGE_OVERRIDE(name)                                \
  void visit_##name(ast::name* node) override {                       \
    check_and_add(node);                                              \
    TraversingVisitor::visit_##name(node);                            \
  }

  // Unit is handled specially in collect(), so we skip the override.
  // Import and Export need specialized handling below.

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

  // Import: the base TraversingVisitor does nothing, but we want to visit
  // import segments, prefix, and show identifiers.
  void visit_Import(ast::Import* node) override {
    check_and_add(node);
    for (int i = 0; i < node->segments().length(); i++) {
      node->segments()[i]->accept(this);
    }
    if (node->prefix() != null) {
      node->prefix()->accept(this);
    }
    for (int i = 0; i < node->show_identifiers().length(); i++) {
      node->show_identifiers()[i]->accept(this);
    }
  }

  // Export: the base TraversingVisitor does nothing, but we want to visit
  // the export identifiers.
  void visit_Export(ast::Export* node) override {
    check_and_add(node);
    for (int i = 0; i < node->identifiers().length(); i++) {
      node->identifiers()[i]->accept(this);
    }
  }

  // Unit is handled in collect(), so the visitor override is a no-op.
  void visit_Unit(ast::Unit* node) override {}
};

/// Converts a 1-based (line, column) pair to a Source::Position for the given source.
///
/// The column is in UTF-16 code units (as per the LSP specification), so
/// multi-byte UTF-8 sequences that encode characters outside the BMP are
/// counted as 2 UTF-16 code units (a surrogate pair).
///
/// Out-of-range positions are clamped to the end of the line or file rather
/// than aborting.
static Source::Position line_column_to_position(Source* source, int line, int utf16_column) {
  const uint8* text = source->text();
  int size = source->size();
  int offset = 0;

  // Skip to the correct line.
  int current_line = 1;
  while (current_line < line && offset < size) {
    int c = text[offset++];
    if (c == '\n' || c == '\r') {
      int other = (c == '\n') ? '\r' : '\n';
      if (offset < size && text[offset] == other) offset++;
      current_line++;
    }
  }
  if (offset >= size) {
    return source->range(size, size).from();
  }

  // Advance within the line, counting UTF-16 code units.
  for (int i = 1; i < utf16_column; i++) {
    if (offset >= size || text[offset] == '\n' || text[offset] == '\r') {
      // Column is past end of line; clamp.
      break;
    }
    int nb_bytes = Utils::bytes_in_utf_8_sequence(text[offset]);
    offset += nb_bytes;
    // A 4-byte UTF-8 sequence encodes a supplementary character, which
    // takes 2 UTF-16 code units (a surrogate pair).
    if (nb_bytes > 3) i++;
  }
  if (offset > size) offset = size;
  return source->range(offset, offset).from();
}

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

    auto source_position = line_column_to_position(source, line, column);
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
