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
#include "token.h"

namespace toit {
namespace compiler {

using namespace ast;

namespace {

static const int INDENT_STEP = 2;
// Continuation indent for a broken Call's arguments. Args on their own line
// (not sharing the target's line) sit at `statement_indent +
// CALL_CONTINUATION_STEP`. Matches the Toit convention observed in the
// reference corpus.
static const int CALL_CONTINUATION_STEP = 4;

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
// Currently recurses into Class members, Method bodies, If (with optional
// else-if chain and final else), While, For, TryFinally, and the body of
// a Call's trailing Block or Lambda argument. Blocks / Lambdas in other
// positions still ride with their enclosing statement.
class Formatter {
 public:
  Formatter(Unit* unit, List<Scanner::Comment> comments, FormatOptions options)
      : unit_(unit)
      , source_(unit->source())
      , text_(unit->source()->text())
      , size_(unit->source()->size())
      , comments_(comments)
      , options_(options) {}

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
  FormatOptions options_;
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

  // Returns the offset of the first non-trivia byte in [from, limit), or
  // `limit` if none found. Skips whitespace, newlines, line comments
  // (// ...), and block comments (/* ... */).
  int find_next_significant(int from, int limit) const {
    while (from < limit) {
      uint8 c = text_[from];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        from++;
        continue;
      }
      if (c == '/' && from + 1 < limit) {
        uint8 next = text_[from + 1];
        if (next == '/') {
          while (from < limit && text_[from] != '\n') from++;
          continue;
        }
        if (next == '*') {
          from += 2;
          while (from + 1 < limit
                 && !(text_[from] == '*' && text_[from + 1] == '/')) {
            from++;
          }
          if (from + 1 < limit) from += 2;
          else from = limit;
          continue;
        }
      }
      return from;
    }
    return limit;
  }

  // Emits bytes from source_cursor_ through to `next_body_line_start`, with
  // the line containing the keyword (e.g. `else:` or `finally:`) re-indented
  // to `indent`. Used to re-indent the header of a second suite following
  // the first (if/else, try/finally).
  void emit_continuation_header(int next_body_line_start, int indent) {
    int keyword_start = find_next_significant(source_cursor_, next_body_line_start);
    if (keyword_start < next_body_line_start) {
      emit_range_reindent(keyword_start, next_body_line_start, indent);
    } else {
      advance_to(next_body_line_start);
    }
  }

  void emit_stmt(Expression* stmt, int indent) {
    // Freeze rule: a statement that contains a multi-line `/* ... */`
    // block comment is emitted as a verbatim leaf (Δ-shift only). The
    // author probably aligned text visually with the `/*`; finer
    // re-indent via the body-recursing dispatches would break that.
    int stmt_from = pos(stmt->full_range().from());
    int stmt_to = pos(stmt->full_range().to());
    if (has_interior_multiline_block_comment(stmt_from, stmt_to)) {
      emit_leaf(stmt, indent);
      return;
    }

    // Flat-test mode: try to emit every statement-position expression in
    // its flat form first. Only kicks in for expression kinds the flat
    // emitter knows how to render — which excludes If/While/For and
    // Calls with Block/Lambda arguments, so the body-recursing dispatches
    // below still run for those.
    if (options_.force_flat && emit_stmt_flat(stmt, indent)) return;

    if (stmt->is_Call()) {
      emit_call(stmt->as_Call(), indent);
      return;
    }
    if (stmt->is_If()) {
      if (emit_if(stmt->as_If(), indent)) return;
    } else if (stmt->is_While()) {
      auto body = as_suite_body(stmt->as_While()->body());
      if (!body.is_empty() && emit_with_suite(stmt, body, indent)) return;
    } else if (stmt->is_For()) {
      auto body = as_suite_body(stmt->as_For()->body());
      if (!body.is_empty() && emit_with_suite(stmt, body, indent)) return;
    } else if (stmt->is_TryFinally()) {
      if (emit_try_finally(stmt->as_TryFinally(), indent)) return;
    }
    emit_leaf(stmt, indent);
  }

  // Flat-mode emission of a statement-position expression. Re-indents the
  // first line to `indent` and writes the expression's canonical flat
  // form, with parens inserted around nested expressions where necessary
  // to keep the re-parsed AST equivalent.
  //
  // Returns false when we don't know how to flatten this expression
  // safely — the caller falls back to verbatim leaf emission.
  bool emit_stmt_flat(Expression* stmt, int indent) {
    if (!can_emit_flat(stmt)) return false;

    int start = pos(stmt->full_range().from());
    int end = pos(stmt->full_range().to());
    // Flat emission is built from AST fields, which don't carry trivia.
    // Any comment that would be affected by horizontal reshaping — in
    // the statement's byte range, OR on the same line as its last token
    // (trailing EOL comments) — locks the layout. Per the brainstorm
    // rule: a line with an EOL `//` can only have its indentation
    // changed, never be split or collapsed.
    if (has_line_locking_comment(start, end)) return false;

    int line_start = find_line_start(start);
    if (line_start < source_cursor_) return false;
    if (!is_leading_whitespace(line_start, start)) return false;

    advance_to(line_start);
    emit_spaces(indent);
    source_cursor_ = end;

    std::string buffer;
    emit_expr_flat(stmt, PRECEDENCE_NONE, &buffer);
    output_.append(buffer);
    return true;
  }

  // Whether any Scanner::Comment sits in a position that would be
  // affected by horizontally reshaping the statement [from, to). That's:
  //
  // (a) any comment whose range starts inside [from, to) — interior
  //     comments that would be silently dropped by AST-only emission,
  //     including inline `/*...*/` between tokens and `//` on continuation
  //     lines of a broken statement.
  //
  // (b) any comment whose range starts *after* `to` but *before* the end
  //     of the line that `to` sits on — a trailing EOL `//` or inline
  //     `/*...*/` after the last token of a single-line statement.
  //     Collapsing or splitting such a line would move the comment
  //     relative to the tokens it was describing.
  //
  // Linear scan — comments_ is usually short; can move to a bsearch if
  // profiling ever cares.
  bool has_line_locking_comment(int from, int to) const {
    // Extend `to` to the end of the line it sits on — catches trailing
    // same-line comments.
    int line_end = to;
    while (line_end < size_ && text_[line_end] != '\n') line_end++;
    for (int i = 0; i < comments_.length(); i++) {
      int cf = pos(comments_[i].range().from());
      if (cf >= from && cf < line_end) return true;
    }
    return false;
  }

  // Whether [from, to) contains a `/* ... */` comment that actually spans
  // more than one source line. Line-spanning block comments freeze the
  // enclosing statement: the author probably aligned something visually
  // against the `/*`, and the safest behaviour is to reproduce the whole
  // statement verbatim (Δ-shift only, no finer re-indent).
  bool has_interior_multiline_block_comment(int from, int to) const {
    for (int i = 0; i < comments_.length(); i++) {
      auto c = comments_[i];
      if (!c.is_multiline()) continue;  // skip '// ...'
      int cf = pos(c.range().from());
      int ct = pos(c.range().to());
      if (cf < from || ct > to) continue;
      for (int j = cf; j < ct; j++) {
        if (text_[j] == '\n') return true;
      }
    }
    return false;
  }

  // Whether we have a flat-form implementation for this expression kind.
  // Conservative — returns false for anything that would require
  // sub-renderings we haven't built yet.
  bool can_emit_flat(Expression* expr) const {
    if (expr == null) return false;
    expr = peel_parens(expr);
    if (expr->is_Identifier() || expr->is_LiteralNull()
        || expr->is_LiteralUndefined() || expr->is_LiteralBoolean()
        || expr->is_LiteralInteger() || expr->is_LiteralCharacter()
        || expr->is_LiteralFloat() || expr->is_LiteralString()) {
      return has_reliable_full_range(expr);
    }
    if (expr->is_Binary()) {
      Binary* b = expr->as_Binary();
      return can_emit_flat(b->left()) && can_emit_flat(b->right());
    }
    if (expr->is_Unary()) {
      return can_emit_flat(expr->as_Unary()->expression());
    }
    if (expr->is_Dot()) {
      return can_emit_flat(expr->as_Dot()->receiver());
    }
    if (expr->is_Index()) {
      Index* idx = expr->as_Index();
      if (!can_emit_flat(idx->receiver())) return false;
      for (auto arg : idx->arguments()) {
        if (!can_emit_flat(arg)) return false;
      }
      return true;
    }
    if (expr->is_IndexSlice()) {
      IndexSlice* slice = expr->as_IndexSlice();
      if (!can_emit_flat(slice->receiver())) return false;
      if (slice->from() != null && !can_emit_flat(slice->from())) return false;
      if (slice->to() != null && !can_emit_flat(slice->to())) return false;
      return true;
    }
    if (expr->is_LiteralList()) {
      for (auto e : expr->as_LiteralList()->elements()) {
        if (!can_emit_flat(e)) return false;
      }
      return true;
    }
    if (expr->is_LiteralByteArray()) {
      for (auto e : expr->as_LiteralByteArray()->elements()) {
        if (!can_emit_flat(e)) return false;
      }
      return true;
    }
    if (expr->is_LiteralSet()) {
      for (auto e : expr->as_LiteralSet()->elements()) {
        if (!can_emit_flat(e)) return false;
      }
      return true;
    }
    if (expr->is_LiteralMap()) {
      LiteralMap* m = expr->as_LiteralMap();
      for (auto k : m->keys()) {
        if (!can_emit_flat(k)) return false;
      }
      for (auto v : m->values()) {
        if (!can_emit_flat(v)) return false;
      }
      return true;
    }
    if (expr->is_Call()) {
      Call* c = expr->as_Call();
      if (!can_emit_flat(c->target())) return false;
      for (auto arg : c->arguments()) {
        // Block/Lambda args aren't flattenable — they'd need their
        // bodies emitted and those span multiple lines by definition.
        if (arg->is_Block() || arg->is_Lambda()) return false;
        if (!can_emit_flat(arg)) return false;
      }
      return true;
    }
    if (expr->is_NamedArgument()) {
      NamedArgument* na = expr->as_NamedArgument();
      return na->expression() == null || can_emit_flat(na->expression());
    }
    if (expr->is_Nullable()) {
      return can_emit_flat(expr->as_Nullable()->type());
    }
    if (expr->is_LiteralStringInterpolation()) {
      // Interpolated strings are intricate to reconstruct (the `$ident` /
      // `$(expr)` / format-spec forms live in the source bytes, not the
      // AST fields directly). Treat as flat-emittable only when the
      // whole thing sits on a single line — then the fallback verbatim
      // emission covers it.
      int from = pos(expr->full_range().from());
      int to = pos(expr->full_range().to());
      Shape s = shape_from_source_range(text_, from, to);
      return s.is_single_line();
    }
    if (expr->is_BreakContinue()) {
      auto v = expr->as_BreakContinue()->value();
      return v == null || can_emit_flat(v);
    }
    if (expr->is_Return()) {
      auto v = expr->as_Return()->value();
      return v == null || can_emit_flat(v);
    }
    if (expr->is_DeclarationLocal()) {
      DeclarationLocal* d = expr->as_DeclarationLocal();
      if (d->type() != null && !can_emit_flat(d->type())) return false;
      if (d->value() != null && !can_emit_flat(d->value())) return false;
      return true;
    }
    return false;
  }

  static Expression* peel_parens(Expression* e) {
    while (e != null && e->is_Parenthesis()) {
      e = e->as_Parenthesis()->expression();
    }
    return e;
  }

  // Appends the flat form of `expr` to `out`. `outer_prec` is the
  // precedence of the enclosing operator (PRECEDENCE_NONE at the top
  // level) — sub-expressions with strictly lower precedence get wrapped
  // in parens. Equal-precedence wrapping is intentionally aggressive
  // (always wrap) because preserving left/right associativity by rule
  // would require per-kind details; over-paren is AST-safe since
  // ast_equivalent strips Parenthesis wrappers.
  void emit_element_list(List<Expression*> elements,
                         const char* open,
                         const char* close,
                         std::string* out) {
    out->append(open);
    for (int i = 0; i < elements.length(); i++) {
      if (i > 0) out->append(", ");
      emit_expr_flat(elements[i], PRECEDENCE_NONE, out);
    }
    out->append(close);
  }

  void emit_expr_flat(Expression* expr, int outer_prec, std::string* out) {
    expr = peel_parens(expr);
    if (expr->is_Binary()) {
      Binary* b = expr->as_Binary();
      int prec = Token::precedence(b->kind());
      bool parens = prec <= outer_prec && outer_prec != PRECEDENCE_NONE;
      if (parens) out->append("(");
      emit_expr_flat(b->left(), prec, out);
      out->append(" ");
      out->append(Token::symbol(b->kind()).c_str());
      out->append(" ");
      emit_expr_flat(b->right(), prec, out);
      if (parens) out->append(")");
      return;
    }
    if (expr->is_Unary()) {
      Unary* u = expr->as_Unary();
      // Unary binds tighter than every binary operator — treat it as
      // PRECEDENCE_POSTFIX for the purpose of wrapping the operand.
      bool parens = PRECEDENCE_POSTFIX <= outer_prec && outer_prec != PRECEDENCE_NONE;
      if (parens) out->append("(");
      const char* op = Token::symbol(u->kind()).c_str();
      if (u->prefix()) {
        out->append(op);
        // `not` is a keyword, separate with a space; punctuation operators stay glued.
        if (u->kind() == Token::NOT) out->append(" ");
        emit_expr_flat(u->expression(), PRECEDENCE_POSTFIX, out);
      } else {
        emit_expr_flat(u->expression(), PRECEDENCE_POSTFIX, out);
        out->append(op);
      }
      if (parens) out->append(")");
      return;
    }
    if (expr->is_Dot()) {
      Dot* d = expr->as_Dot();
      emit_expr_flat(d->receiver(), PRECEDENCE_POSTFIX, out);
      out->append(".");
      // Dot's name is an Identifier — append its source bytes directly.
      int nfrom = pos(d->name()->full_range().from());
      int nto = pos(d->name()->full_range().to());
      out->append(reinterpret_cast<const char*>(text_) + nfrom, nto - nfrom);
      return;
    }
    if (expr->is_Index()) {
      Index* idx = expr->as_Index();
      emit_expr_flat(idx->receiver(), PRECEDENCE_POSTFIX, out);
      out->append("[");
      bool first = true;
      for (auto arg : idx->arguments()) {
        if (!first) out->append(", ");
        // Inside `[...]` the precedence context is reset — no outer
        // operator can pull expressions apart across the brackets.
        emit_expr_flat(arg, PRECEDENCE_NONE, out);
        first = false;
      }
      out->append("]");
      return;
    }
    if (expr->is_IndexSlice()) {
      IndexSlice* slice = expr->as_IndexSlice();
      emit_expr_flat(slice->receiver(), PRECEDENCE_POSTFIX, out);
      out->append("[");
      if (slice->from() != null) {
        emit_expr_flat(slice->from(), PRECEDENCE_NONE, out);
      }
      out->append("..");
      if (slice->to() != null) {
        emit_expr_flat(slice->to(), PRECEDENCE_NONE, out);
      }
      out->append("]");
      return;
    }
    if (expr->is_LiteralList()) {
      emit_element_list(expr->as_LiteralList()->elements(), "[", "]", out);
      return;
    }
    if (expr->is_LiteralByteArray()) {
      emit_element_list(expr->as_LiteralByteArray()->elements(), "#[", "]", out);
      return;
    }
    if (expr->is_LiteralSet()) {
      emit_element_list(expr->as_LiteralSet()->elements(), "{", "}", out);
      return;
    }
    if (expr->is_LiteralMap()) {
      LiteralMap* m = expr->as_LiteralMap();
      // Empty map is `{:}` — `{}` would parse as a Set literal instead.
      if (m->keys().is_empty()) {
        out->append("{:}");
        return;
      }
      out->append("{");
      for (int i = 0; i < m->keys().length(); i++) {
        if (i > 0) out->append(", ");
        emit_expr_flat(m->keys()[i], PRECEDENCE_NONE, out);
        out->append(": ");
        emit_expr_flat(m->values()[i], PRECEDENCE_NONE, out);
      }
      out->append("}");
      return;
    }
    if (expr->is_Call()) {
      Call* c = expr->as_Call();
      // Call in Toit is greedy: once parsed as a Call, it keeps
      // absorbing subsequent tokens (including binary operators) into
      // its argument list until the end of the expression. So any time
      // we emit a Call that isn't at the top of a statement — anything
      // where outer_prec != PRECEDENCE_NONE — we have to wrap it in
      // parens, otherwise the enclosing binary/unary/call context would
      // be silently pulled into the Call on re-parse.
      bool parens = outer_prec != PRECEDENCE_NONE;
      if (parens) out->append("(");
      emit_expr_flat(c->target(), PRECEDENCE_POSTFIX, out);
      for (auto arg : c->arguments()) {
        out->append(" ");
        // Wrap arguments that themselves have binary/unary structure —
        // again, Call absorbs across binary operators, so `foo a + b`
        // parses as `Call(foo, [Binary(+, a, b)])`. When the AST wants
        // `Binary(+, Call(foo, [a]), b)` we must write `foo a + b` as
        // `(foo a) + b`; when the AST wants the former, no wrap needed.
        emit_expr_flat(arg, PRECEDENCE_POSTFIX, out);
      }
      if (parens) out->append(")");
      return;
    }
    if (expr->is_NamedArgument()) {
      NamedArgument* na = expr->as_NamedArgument();
      out->append(na->inverted() ? "--no-" : "--");
      int nfrom = pos(na->name()->full_range().from());
      int nto = pos(na->name()->full_range().to());
      out->append(reinterpret_cast<const char*>(text_) + nfrom, nto - nfrom);
      if (na->expression() != null) {
        out->append("=");
        emit_expr_flat(na->expression(), PRECEDENCE_POSTFIX, out);
      }
      return;
    }
    if (expr->is_Nullable()) {
      emit_expr_flat(expr->as_Nullable()->type(), PRECEDENCE_POSTFIX, out);
      out->append("?");
      return;
    }
    if (expr->is_BreakContinue()) {
      BreakContinue* bc = expr->as_BreakContinue();
      out->append(bc->is_break() ? "break" : "continue");
      if (bc->label() != null) {
        out->append(".");
        int lfrom = pos(bc->label()->full_range().from());
        int lto = pos(bc->label()->full_range().to());
        out->append(reinterpret_cast<const char*>(text_) + lfrom, lto - lfrom);
      }
      if (bc->value() != null) {
        out->append(" ");
        // The value is parsed as a full expression, no outer operator —
        // use PRECEDENCE_NONE so `break a + b` stays unwrapped.
        emit_expr_flat(bc->value(), PRECEDENCE_NONE, out);
      }
      return;
    }
    if (expr->is_Return()) {
      Return* r = expr->as_Return();
      out->append("return");
      if (r->value() != null) {
        out->append(" ");
        emit_expr_flat(r->value(), PRECEDENCE_NONE, out);
      }
      return;
    }
    if (expr->is_DeclarationLocal()) {
      DeclarationLocal* d = expr->as_DeclarationLocal();
      int nfrom = pos(d->name()->full_range().from());
      int nto = pos(d->name()->full_range().to());
      out->append(reinterpret_cast<const char*>(text_) + nfrom, nto - nfrom);
      if (d->type() != null) {
        out->append("/");
        emit_expr_flat(d->type(), PRECEDENCE_POSTFIX, out);
      }
      if (d->value() != null) {
        out->append(" ");
        out->append(Token::symbol(d->kind()).c_str());
        out->append(" ");
        emit_expr_flat(d->value(), PRECEDENCE_NONE, out);
      }
      return;
    }
    // Leaf: copy source bytes verbatim.
    int from = pos(expr->full_range().from());
    int to = pos(expr->full_range().to());
    out->append(reinterpret_cast<const char*>(text_) + from, to - from);
  }

  bool emit_try_finally(TryFinally* tf, int indent) {
    auto body = tf->body() == null
        ? List<Expression*>()
        : tf->body()->expressions();
    auto handler = tf->handler() == null
        ? List<Expression*>()
        : tf->handler()->expressions();
    if (body.is_empty() || handler.is_empty()) return false;

    int node_start = pos(tf->full_range().from());
    int node_end = pos(tf->full_range().to());
    int body_first_line_start = find_line_start(pos(body.first()->full_range().from()));
    if (body_first_line_start <= node_start) return false;

    emit_range_reindent(node_start, body_first_line_start, indent);
    for (auto expr : body) {
      emit_stmt(expr, indent + INDENT_STEP);
    }

    int handler_first_line_start =
        find_line_start(pos(handler.first()->full_range().from()));
    emit_continuation_header(handler_first_line_start, indent);
    for (auto expr : handler) {
      emit_stmt(expr, indent + INDENT_STEP);
    }

    advance_to(node_end);
    return true;
  }

  // Emits an If at `indent`, including any else-if chain and a final else
  // branch. Returns false if the initial yes body can't be handled (inline
  // body, empty body); the caller should fall back to leaf.
  //
  // Parser shape: `else if ...` is If.no = inner If (not a Sequence). So
  // we walk the .no chain while it's an If, and treat each inner If's
  // header as a continuation header spanning until its own body's first
  // line — that way `else if cond:` shares a line with its keyword and
  // gets re-indented as a single unit.
  bool emit_if(If* if_node, int indent) {
    auto yes_body = as_suite_body(if_node->yes());
    if (yes_body.is_empty()) return false;

    int node_start = pos(if_node->full_range().from());
    int node_end = pos(if_node->full_range().to());
    int yes_first_line_start = find_line_start(pos(yes_body.first()->full_range().from()));
    if (yes_first_line_start <= node_start) return false;

    emit_range_reindent(node_start, yes_first_line_start, indent);
    for (auto expr : yes_body) {
      emit_stmt(expr, indent + INDENT_STEP);
    }

    // Walk the else-if chain. Each step re-indents the `else if cond:`
    // keyword line and recurses into its yes body.
    If* cur = if_node;
    while (cur->no() != null && cur->no()->is_If()) {
      If* next = cur->no()->as_If();
      auto next_yes = as_suite_body(next->yes());
      if (next_yes.is_empty()) break;  // fall through to verbatim tail
      int next_body_line_start =
          find_line_start(pos(next_yes.first()->full_range().from()));
      emit_continuation_header(next_body_line_start, indent);
      for (auto expr : next_yes) {
        emit_stmt(expr, indent + INDENT_STEP);
      }
      cur = next;
    }

    // Final else branch (a Sequence, not an If), if any.
    if (cur->no() != null && !cur->no()->is_If()) {
      auto final_no = as_suite_body(cur->no());
      if (!final_no.is_empty()) {
        int no_first_line_start =
            find_line_start(pos(final_no.first()->full_range().from()));
        emit_continuation_header(no_first_line_start, indent);
        for (auto expr : final_no) {
          emit_stmt(expr, indent + INDENT_STEP);
        }
      }
    }

    advance_to(node_end);
    return true;
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

    if (source_shape.is_single_line()) {
      if (try_emit_call_flat_canonical(call, indent)) return;
      emit_leaf(call, indent);
      return;
    }

    // Multi-line Call. If the last argument is a Block or Lambda with a
    // multi-line body, recurse into that body so its statements re-indent
    // to the Call's indent + INDENT_STEP. Typical Toit idiom:
    //   list.do: | x |
    //     print x
    if (!call->arguments().is_empty()) {
      Expression* last = call->arguments().last();
      Sequence* body = null;
      if (last->is_Block()) body = last->as_Block()->body();
      else if (last->is_Lambda()) body = last->as_Lambda()->body();
      if (body != null && !body->expressions().is_empty()) {
        if (emit_call_with_trailing_suite(call, body->expressions(), indent)) {
          return;
        }
      }
    }
    // No trailing block: try to canonicalize the continuation indent of
    // args that sit on their own line. Preserves the source's decision
    // about which args share the target's line vs go on continuation
    // lines; only fixes the indent of the continuation lines themselves.
    if (try_emit_call_broken_canonical(call, indent)) return;
    emit_leaf(call, indent);
  }

  // For a multi-line Call whose continuation args live on their own lines,
  // re-indents those lines to `indent + CALL_CONTINUATION_STEP`.
  // Returns false if guards fail (line-locking comments, unreliable
  // full_range, no arg on its own line, etc.); caller falls back to leaf.
  bool try_emit_call_broken_canonical(Call* call, int indent) {
    int call_start = pos(call->full_range().from());
    int call_end = pos(call->full_range().to());
    if (has_line_locking_comment(call_start, call_end)) return false;
    if (!has_reliable_full_range(call->target())) return false;
    for (auto arg : call->arguments()) {
      if (arg->is_Block() || arg->is_Lambda()) return false;
      if (!has_reliable_full_range(arg)) return false;
    }

    int call_line_start = find_line_start(call_start);
    if (call_line_start < source_cursor_) return false;
    if (!is_leading_whitespace(call_line_start, call_start)) return false;

    // Find the first arg that sits on a line different from the call's
    // target line. If none, this "broken" call is really single-line
    // (shouldn't happen given source_shape.is_single_line() check above,
    // but guard anyway).
    int first_break = -1;
    for (int i = 0; i < call->arguments().length(); i++) {
      int arg_line = find_line_start(
          pos(call->arguments()[i]->full_range().from()));
      if (arg_line > call_line_start) {
        first_break = i;
        break;
      }
    }
    if (first_break < 0) return false;

    // Emit the call's first line (target + any same-line args) at `indent`.
    int break_line_start = find_line_start(
        pos(call->arguments()[first_break]->full_range().from()));
    emit_range_reindent(call_start, break_line_start, indent);

    // Re-indent each continuation arg.
    int continuation_indent = indent + CALL_CONTINUATION_STEP;
    for (int i = first_break; i < call->arguments().length(); i++) {
      auto arg = call->arguments()[i];
      int arg_start = pos(arg->full_range().from());
      int arg_end = pos(arg->full_range().to());
      emit_range_reindent(arg_start, arg_end, continuation_indent);
    }

    advance_to(call_end);
    return true;
  }

  // For `foo arg: | params | body...`, emits the Call's header up to the
  // body's first line, recurses each body expression at indent +
  // INDENT_STEP, then emits any trailing bytes of the Call. Returns false
  // if the body shares a line with the Call's start (inline body).
  bool emit_call_with_trailing_suite(Call* call,
                                     List<Expression*> body,
                                     int indent) {
    int call_start = pos(call->full_range().from());
    int call_end = pos(call->full_range().to());
    int body_first_line_start =
        find_line_start(pos(body.first()->full_range().from()));
    if (body_first_line_start <= call_start) return false;

    emit_range_reindent(call_start, body_first_line_start, indent);
    for (auto expr : body) {
      emit_stmt(expr, indent + INDENT_STEP);
    }
    advance_to(call_end);
    return true;
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
    // A line with an EOL comment (`//` or `/*...*/` after the last token)
    // can only have its indentation changed — not its internal spacing.
    // Fall back to verbatim.
    if (has_line_locking_comment(call_start, call_end)) return false;
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

    int original_indent = call_start - line_start;
    int delta = indent - original_indent;
    // Shift preceding trivia (blank lines, standalone comments) by the
    // same delta we're about to apply to this call's first line.
    emit_with_indent_shift(source_cursor_, line_start, delta);
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

    // Shift any preceding trivia (blank lines, standalone comments) by the
    // same delta we're about to apply to this statement. Keeps comment
    // lines between body statements aligned with the body's new indent.
    emit_with_indent_shift(source_cursor_, line_start, delta);
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
                   int* formatted_size,
                   FormatOptions options) {
  Formatter formatter(unit, comments, options);
  formatter.format();
  return formatter.take_output(formatted_size);
}

} // namespace toit::compiler
} // namespace toit
