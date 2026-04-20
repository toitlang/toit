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

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../top.h"
#include "format.h"
#include "ast.h"
#include "sources.h"

namespace toit {
namespace compiler {

using namespace ast;

namespace {

static const int INDENT_STEP = 2;

// Walks the AST, re-indenting statement-equivalents based on their nesting
// depth in the tree. Horizontal layout within a statement is left verbatim;
// continuation lines shift by the same delta as the statement's first line.
//
// Scope at M2: recursion into Class members and Method bodies only.
// If/While/For/TryFinally/Lambda/Block bodies are treated as leaves (their
// contents shift with the enclosing statement).
class Formatter {
 public:
  Formatter(Unit* unit, List<Scanner::Comment> comments)
      : unit_(unit)
      , source_(unit->source())
      , text_(unit->source()->text())
      , size_(unit->source()->size())
      , comments_(comments) {}

  uint8* take_output(int* size_out) {
    *size_out = output_.size();
    uint8* buf = unvoid_cast<uint8*>(malloc(output_.size()));
    memcpy(buf, output_.data(), output_.size());
    return buf;
  }

  void format() {
    std::vector<Node*> top;
    top.reserve(unit_->imports().length()
                + unit_->exports().length()
                + unit_->declarations().length());
    for (auto n : unit_->imports()) top.push_back(n);
    for (auto n : unit_->exports()) top.push_back(n);
    for (auto n : unit_->declarations()) top.push_back(n);
    std::sort(top.begin(), top.end(), [this](Node* a, Node* b) {
      return pos(a->full_range().from()) < pos(b->full_range().from());
    });

    for (Node* node : top) {
      emit_decl(node, /*indent=*/0);
    }
    // Trailing whitespace / comments at end of file.
    advance_to(size_);
  }

 private:
  Unit* unit_;
  Source* source_;
  const uint8* text_;
  int size_;
  List<Scanner::Comment> comments_;
  std::string output_;
  int source_cursor_ = 0;

  int pos(Source::Position p) const { return source_->offset_in_source(p); }

  void emit_source(int from, int to) {
    if (from < to) {
      output_.append(reinterpret_cast<const char*>(text_) + from, to - from);
    }
  }

  void advance_to(int to) {
    emit_source(source_cursor_, to);
    source_cursor_ = to;
  }

  void emit_spaces(int n) {
    output_.append(n, ' ');
  }

  // Returns the byte offset of the start of the line containing `offset`.
  int find_line_start(int offset) const {
    while (offset > 0 && text_[offset - 1] != '\n') offset--;
    return offset;
  }

  // Whether `[line_start, first_byte)` contains only spaces/tabs.
  bool is_leading_whitespace(int line_start, int first_byte) const {
    for (int i = line_start; i < first_byte; i++) {
      if (text_[i] != ' ' && text_[i] != '\t') return false;
    }
    return true;
  }

  // Dispatch: emit a declaration, recursing into Class and Method bodies.
  void emit_decl(Node* node, int indent) {
    if (node->is_Class() && !node->as_Class()->members().is_empty()) {
      emit_class(node->as_Class(), indent);
      return;
    }
    if (node->is_Method()) {
      Method* method = node->as_Method();
      if (method->body() != null && !method->body()->expressions().is_empty()) {
        emit_method(method, indent);
        return;
      }
    }
    emit_leaf(node, indent);
  }

  void emit_class(Class* klass, int indent) {
    int node_start = pos(klass->full_range().from());
    int node_end = pos(klass->full_range().to());
    int first_member_line_start =
        find_line_start(pos(klass->members().first()->full_range().from()));

    // Header: re-indent and emit bytes up to (but not including) the first
    // member's leading whitespace. The member's own emit will rewrite that.
    emit_range_reindent(node_start, first_member_line_start, indent);

    for (auto member : klass->members()) {
      emit_decl(member, indent + INDENT_STEP);
    }

    advance_to(node_end);
  }

  void emit_method(Method* method, int indent) {
    int node_start = pos(method->full_range().from());
    int node_end = pos(method->full_range().to());
    auto exprs = method->body()->expressions();
    int first_expr_start = pos(exprs.first()->full_range().from());
    int first_expr_line_start = find_line_start(first_expr_start);

    // If the first body expression shares a line with the method header
    // (inline body like `foo: return 42`), we can't split the header from
    // the body — emit the whole thing as a leaf.
    if (first_expr_line_start <= node_start) {
      emit_leaf(method, indent);
      return;
    }

    emit_range_reindent(node_start, first_expr_line_start, indent);

    for (auto expr : exprs) {
      emit_stmt(expr, indent + INDENT_STEP);
    }

    advance_to(node_end);
  }

  void emit_stmt(Expression* stmt, int indent) {
    // M2: leaves (no deeper recursion into If/While/For/etc).
    emit_leaf(stmt, indent);
  }

  // Re-indent the first line of this node to `indent`, delta-shifting any
  // continuation lines within its range. Falls back to verbatim if the node
  // doesn't start on its own line.
  void emit_leaf(Node* node, int indent) {
    int start = pos(node->full_range().from());
    int end = pos(node->full_range().to());
    emit_range_reindent(start, end, indent);
  }

  // Emits bytes [from, to) with the first line re-indented to `indent` and
  // continuation lines delta-shifted by the same amount.
  void emit_range_reindent(int from, int to, int indent) {
    int line_start = find_line_start(from);

    // If there's non-whitespace content between line_start and `from`, or if
    // the cursor has already consumed past line_start, we can't safely
    // re-indent this node's first line. Emit verbatim.
    if (line_start < source_cursor_ || !is_leading_whitespace(line_start, from)) {
      advance_to(to);
      return;
    }

    int original_indent = from - line_start;
    int delta = indent - original_indent;

    // Emit up to the start of the line (trivia from previous decl / comments).
    advance_to(line_start);
    // Replace original indent with canonical.
    emit_spaces(indent);
    source_cursor_ = from;
    // Emit the node bytes, shifting continuation-line indents by delta.
    emit_with_indent_shift(from, to, delta);
  }

  void emit_with_indent_shift(int from, int to, int delta) {
    int i = from;
    while (i < to) {
      uint8 c = text_[i];
      output_.push_back(c);
      i++;
      if (c != '\n') continue;

      int ws = 0;
      while (i + ws < to && text_[i + ws] == ' ') ws++;
      bool is_blank = (i + ws >= to || text_[i + ws] == '\n');
      if (is_blank) {
        // Keep blank lines blank (don't manufacture indent on them).
        output_.append(reinterpret_cast<const char*>(text_) + i, ws);
      } else {
        int new_ws = std::max(0, ws + delta);
        output_.append(new_ws, ' ');
      }
      i += ws;
    }
    source_cursor_ = to;
  }
};

}  // namespace

uint8* format_unit(Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size) {
  Formatter formatter(unit, comments);
  formatter.format();
  return formatter.take_output(formatted_size);
}

} // namespace toit::compiler
} // namespace toit
