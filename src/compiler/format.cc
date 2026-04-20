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
#include <unordered_map>
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

// The shape of an already-rendered subtree. Parents use this to decide
// flat-vs-broken layouts without re-measuring. Inside-out: a parent only
// sees a shape, never a budget from above.
//
// `last_line_width` is intentionally omitted — Toit's indentation model
// rarely continues on the same line after a multi-line chunk. Add if a
// real case demands it.
struct Shape {
  int first_line_width = 0;
  int max_width = 0;
  int height = 1;

  bool is_single_line() const { return height == 1; }
};

// Measures the shape of the given byte range as if it were emitted verbatim.
// Used as the initial shape for every node (M3) until per-node shape
// computation lands (M4).
static Shape shape_from_source_range(const uint8* text, int from, int to) {
  Shape s;
  int line_w = 0;
  bool have_first = false;
  for (int i = from; i < to; i++) {
    if (text[i] == '\n') {
      if (!have_first) {
        s.first_line_width = line_w;
        have_first = true;
      }
      if (line_w > s.max_width) s.max_width = line_w;
      s.height++;
      line_w = 0;
    } else {
      line_w++;
    }
  }
  if (!have_first) s.first_line_width = line_w;
  if (line_w > s.max_width) s.max_width = line_w;
  return s;
}

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
  std::unordered_map<Node*, Shape> shapes_;

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
    if (!emit_with_suite(method, method->body()->expressions(), indent)) {
      emit_leaf(method, indent);
    }
  }

  // Emits `node` at `indent`: bytes from node_start up to the first body
  // expression's line start (with the header's first line re-indented to
  // `indent`), then each body expression at indent + INDENT_STEP, then any
  // trailing bytes up to node_end. Returns false if the body is empty or
  // shares a line with the header (inline, e.g. `foo: return 42`); the
  // caller should fall back to verbatim emission.
  bool emit_with_suite(Node* node,
                       List<Expression*> body,
                       int indent) {
    if (body.is_empty()) return false;
    int node_start = pos(node->full_range().from());
    int node_end = pos(node->full_range().to());
    int first_body_start = pos(body.first()->full_range().from());
    int first_body_line_start = find_line_start(first_body_start);
    if (first_body_line_start <= node_start) return false;

    emit_range_reindent(node_start, first_body_line_start, indent);
    for (auto expr : body) {
      emit_stmt(expr, indent + INDENT_STEP);
    }
    advance_to(node_end);
    return true;
  }

  // Returns the expressions of `expr` when it's a Sequence, or an empty list
  // otherwise. The caller can use `is_empty()` to detect both "not a
  // Sequence" and "empty Sequence."
  List<Expression*> as_suite_body(Expression* expr) const {
    if (expr != null && expr->is_Sequence()) {
      return expr->as_Sequence()->expressions();
    }
    return List<Expression*>();
  }

  void emit_stmt(Expression* stmt, int indent) {
    if (stmt->is_Call()) {
      emit_call(stmt->as_Call(), indent);
      return;
    }
    if (stmt->is_If()) {
      If* if_node = stmt->as_If();
      // Only recurse for single-body Ifs (no else). Multi-body Ifs need to
      // re-indent the `else:` line too, which requires scanning for a
      // keyword that is not in the AST. Leaves a follow-up.
      if (if_node->no() == null) {
        auto body = as_suite_body(if_node->yes());
        if (!body.is_empty() && emit_with_suite(stmt, body, indent)) return;
      }
    } else if (stmt->is_While()) {
      auto body = as_suite_body(stmt->as_While()->body());
      if (!body.is_empty() && emit_with_suite(stmt, body, indent)) return;
    } else if (stmt->is_For()) {
      auto body = as_suite_body(stmt->as_For()->body());
      if (!body.is_empty() && emit_with_suite(stmt, body, indent)) return;
    }
    emit_leaf(stmt, indent);
  }

  // Conservatively accept only nodes whose full_range is known to cover
  // every byte of their source text. Composite nodes are reliable iff all
  // of their sub-ranges are reliable.
  bool has_reliable_full_range(Node* node) const {
    if (node->is_Identifier()) return true;
    if (node->is_LiteralNull()) return true;
    if (node->is_LiteralUndefined()) return true;
    if (node->is_LiteralBoolean()) return true;
    if (node->is_LiteralInteger()) return true;
    if (node->is_LiteralCharacter()) return true;
    if (node->is_LiteralFloat()) return true;
    if (node->is_LiteralString()) return true;

    if (node->is_Parenthesis()) {
      return has_reliable_full_range(node->as_Parenthesis()->expression());
    }
    if (node->is_Unary()) {
      return has_reliable_full_range(node->as_Unary()->expression());
    }
    if (node->is_Return()) {
      auto value = node->as_Return()->value();
      return value == null || has_reliable_full_range(value);
    }
    if (node->is_NamedArgument()) {
      auto expr = node->as_NamedArgument()->expression();
      return expr == null || has_reliable_full_range(expr);
    }
    if (node->is_Dot()) {
      return has_reliable_full_range(node->as_Dot()->receiver());
    }
    if (node->is_Index()) {
      Index* idx = node->as_Index();
      if (!has_reliable_full_range(idx->receiver())) return false;
      for (auto arg : idx->arguments()) {
        if (!has_reliable_full_range(arg)) return false;
      }
      return true;
    }
    if (node->is_IndexSlice()) {
      IndexSlice* slice = node->as_IndexSlice();
      if (!has_reliable_full_range(slice->receiver())) return false;
      if (slice->from() != null && !has_reliable_full_range(slice->from())) return false;
      if (slice->to() != null && !has_reliable_full_range(slice->to())) return false;
      return true;
    }

    return false;
  }

  void emit_call(Call* call, int indent) {
    int from = pos(call->full_range().from());
    int to = pos(call->full_range().to());
    Shape source_shape = shape_from_source_range(text_, from, to);
    shapes_[call] = source_shape;

    // M4 decision: preserve source layout (flat stays flat, broken stays
    // broken) but canonicalize flat-form spacing to a single space between
    // tokens. Broken form stays verbatim — continuation-indent
    // canonicalization lands later.
    if (source_shape.is_single_line() && try_emit_call_flat_canonical(call, indent)) {
      return;
    }
    emit_leaf(call, indent);
  }

  // Emits `target arg1 arg2 ...` with single-space separators. Returns false
  // (and emits nothing) if the call is not safe to canonicalize — i.e. there
  // is any non-whitespace content between consecutive tokens (comments), the
  // call does not start on its own line, or the target or any argument has
  // a full_range we can't trust as a contiguous source span.
  bool try_emit_call_flat_canonical(Call* call, int indent) {
    Expression* target = call->target();
    // Guard against AST nodes whose full_range does not cover their complete
    // source span (Index/IndexSlice exclude the receiver, for example).
    // Limit canonicalization to targets and args whose full_range is known
    // to be reliable.
    if (!has_reliable_full_range(target)) return false;
    for (auto arg : call->arguments()) {
      if (!has_reliable_full_range(arg)) return false;
    }

    int call_start = pos(call->full_range().from());
    int call_end = pos(call->full_range().to());
    int line_start = find_line_start(call_start);
    if (line_start < source_cursor_) return false;
    if (!is_leading_whitespace(line_start, call_start)) return false;

    int prev_end = pos(target->full_range().to());
    for (auto arg : call->arguments()) {
      int arg_start = pos(arg->full_range().from());
      for (int i = prev_end; i < arg_start; i++) {
        if (text_[i] != ' ' && text_[i] != '\t') return false;
      }
      prev_end = pos(arg->full_range().to());
    }

    advance_to(line_start);
    output_.append(indent, ' ');

    int target_start = pos(target->full_range().from());
    int target_end = pos(target->full_range().to());
    output_.append(reinterpret_cast<const char*>(text_) + target_start,
                   target_end - target_start);

    for (auto arg : call->arguments()) {
      // A Block argument begins with ':' and must stay glued to the
      // preceding token. Otherwise `foo: body` becomes `foo : body` which
      // parses differently (or fails to parse).
      if (!arg->is_Block()) {
        output_.push_back(' ');
      }
      int arg_start = pos(arg->full_range().from());
      int arg_end = pos(arg->full_range().to());
      output_.append(reinterpret_cast<const char*>(text_) + arg_start,
                     arg_end - arg_start);
    }

    source_cursor_ = call_end;
    return true;
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
