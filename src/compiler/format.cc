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
// Soft width threshold for flat-if-fits decisions. A node's flat form is
// preferred when its rendered width does not exceed this value.
static const int MAX_LINE_WIDTH = 100;
// Tighter threshold for Calls with two or more NamedArguments — the
// config-call shape. Authors routinely break these per-line before the
// standard 100-col limit because each `--option=value` reads as an
// entry in a structured options block.
static const int NAMED_ARG_CALL_WIDTH = 80;
// Minimum NamedArgument count at which the tighter threshold kicks in.
// With fewer args the config-call pattern doesn't apply.
static const int NAMED_ARG_CALL_MIN = 2;
// Tighter threshold for inlined control flow — `if cond: body`,
// `while cond: body`. Inline packs two semantic chunks (header +
// body) on one line; the eye has to visually split before processing
// each part, so it pays to keep the combined width small. Anything
// over this budget breaks to the multi-line form even when the
// general 100-col limit would still allow it.
static const int INLINE_CONTROL_FLOW_WIDTH = 60;

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
    if (to <= source_cursor_) return;
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
      // No body. Two distinct cases:
      //   - `abstract foo -> int` (is_abstract=true): no `:` separator,
      //     truly abstract. Safe to AST-render the header.
      //   - `foo:` (is_abstract=false): `:` separator with empty body.
      //     The source's `:` and trailing whitespace are load-bearing
      //     for the parser (they help disambiguate sibling vs body).
      //     Fall through to emit_leaf to preserve source verbatim.
      if (method->is_abstract()) {
        if (try_emit_method_full_canonical(method, indent)) return;
      }
    }
    if (node->is_Import()) {
      if (try_emit_import_canonical(node->as_Import(), indent)) return;
    }
    if (node->is_Export()) {
      if (try_emit_export_canonical(node->as_Export(), indent)) return;
    }
    if (node->is_Field()) {
      if (try_emit_field_canonical(node->as_Field(), indent)) return;
    }
    emit_leaf(node, indent);
  }

  // Renders a Field declaration from AST with single canonical
  // spacing. Form:
  //
  //   [static] [abstract] name [/Type] [(:= | ::=) initializer]
  //
  // Operator is `::=` for is_final, `:=` otherwise. A field with a
  // type but no initializer omits the operator entirely
  // (`x/int`).
  bool try_emit_field_canonical(Field* field, int indent) {
    int node_start = pos(field->full_range().from());
    int node_end = pos(field->full_range().to());
    if (has_line_locking_comment(node_start, node_end)) return false;
    if (has_interior_multiline_block_comment(node_start, node_end)) return false;
    int line_start = find_line_start(node_start);
    if (line_start < source_cursor_) return false;
    if (!is_leading_whitespace(line_start, node_start)) return false;
    if (field->name() == nullptr) return false;
    if (!has_reliable_full_range(field->name())) return false;
    // Type and initializer go through emit_expr_flat — byte-copying
    // a type like `io.Writer?` would only get `?` (Nullable doesn't
    // override full_range to cover the inner type).
    if (field->type() != nullptr && !can_emit_flat(field->type())) return false;
    if (field->initializer() != nullptr && !can_emit_flat(field->initializer())) {
      return false;
    }

    std::string buf;
    if (field->is_static()) buf.append("static ");
    if (field->is_abstract()) buf.append("abstract ");
    int n_start = pos(field->name()->full_range().from());
    int n_end = pos(field->name()->full_range().to());
    buf.append(reinterpret_cast<const char*>(text_) + n_start, n_end - n_start);
    if (field->type() != nullptr) {
      buf.push_back('/');
      emit_expr_flat(field->type(), PRECEDENCE_POSTFIX, &buf);
    }
    if (field->initializer() != nullptr) {
      buf.append(field->is_final() ? " ::= " : " := ");
      emit_expr_flat(field->initializer(), PRECEDENCE_NONE, &buf);
    }

    int original_indent = node_start - line_start;
    int delta = indent - original_indent;
    emit_with_indent_shift(source_cursor_, line_start, delta);
    emit_spaces(indent);
    output_.append(buf);
    source_cursor_ = node_end;
    return true;
  }

  // Renders an Import declaration from AST. Form:
  //
  //   import [.+] segment.segment.segment [as Prefix | show * | show I1 I2 ...]
  //
  // Single canonical spacing: `import` + space + path + (optional clause
  // with single spaces). Source whitespace inside the import is
  // normalised away.
  bool try_emit_import_canonical(Import* imp, int indent) {
    int node_start = pos(imp->full_range().from());
    int node_end = pos(imp->full_range().to());
    if (has_line_locking_comment(node_start, node_end)) return false;
    if (has_interior_multiline_block_comment(node_start, node_end)) return false;
    int line_start = find_line_start(node_start);
    if (line_start < source_cursor_) return false;
    if (!is_leading_whitespace(line_start, node_start)) return false;
    for (auto seg : imp->segments()) {
      if (!has_reliable_full_range(seg)) return false;
    }
    if (imp->prefix() != nullptr && !has_reliable_full_range(imp->prefix())) {
      return false;
    }
    for (auto id : imp->show_identifiers()) {
      if (!has_reliable_full_range(id)) return false;
    }

    auto bytes = [&](Node* n) -> std::string {
      int s = pos(n->full_range().from());
      int t = pos(n->full_range().to());
      return std::string(reinterpret_cast<const char*>(text_) + s, t - s);
    };

    std::string buf = "import ";
    if (imp->is_relative()) {
      // Leading dots: `.` for current package + one extra `.` per dot_out.
      buf.append(imp->dot_outs() + 1, '.');
    }
    for (int i = 0; i < imp->segments().length(); i++) {
      if (i > 0) buf.push_back('.');
      buf.append(bytes(imp->segments()[i]));
    }
    if (imp->prefix() != nullptr) {
      buf.append(" as ");
      buf.append(bytes(imp->prefix()));
    } else if (imp->show_all()) {
      buf.append(" show *");
    } else if (!imp->show_identifiers().is_empty()) {
      buf.append(" show");
      for (auto id : imp->show_identifiers()) {
        buf.push_back(' ');
        buf.append(bytes(id));
      }
    }

    // `Import::full_range()` doesn't include the `show *` / `show ...`
    // / `as ...` portion of the source — it ends at the last segment /
    // prefix / show-identifier. Advance source_cursor_ past whatever
    // remains on the line (`show *`, trailing whitespace, etc.) so we
    // don't emit it twice.
    int line_end = node_end;
    while (line_end < size_ && text_[line_end] != '\n') line_end++;

    int original_indent = node_start - line_start;
    int delta = indent - original_indent;
    emit_with_indent_shift(source_cursor_, line_start, delta);
    emit_spaces(indent);
    output_.append(buf);
    source_cursor_ = line_end;
    return true;
  }

  // Renders an Export declaration: `export *` or `export I1 I2 ...`.
  bool try_emit_export_canonical(Export* exp, int indent) {
    int node_start = pos(exp->full_range().from());
    int node_end = pos(exp->full_range().to());
    if (has_line_locking_comment(node_start, node_end)) return false;
    if (has_interior_multiline_block_comment(node_start, node_end)) return false;
    int line_start = find_line_start(node_start);
    if (line_start < source_cursor_) return false;
    if (!is_leading_whitespace(line_start, node_start)) return false;
    for (auto id : exp->identifiers()) {
      if (!has_reliable_full_range(id)) return false;
    }

    std::string buf = "export";
    if (exp->export_all()) {
      buf.append(" *");
    } else {
      for (auto id : exp->identifiers()) {
        buf.push_back(' ');
        int s = pos(id->full_range().from());
        int t = pos(id->full_range().to());
        buf.append(reinterpret_cast<const char*>(text_) + s, t - s);
      }
    }

    // Like Import: advance past anything remaining on the line that
    // wasn't covered by Export::full_range() (`*` etc.).
    int line_end = node_end;
    while (line_end < size_ && text_[line_end] != '\n') line_end++;

    int original_indent = node_start - line_start;
    int delta = indent - original_indent;
    emit_with_indent_shift(source_cursor_, line_start, delta);
    emit_spaces(indent);
    output_.append(buf);
    source_cursor_ = line_end;
    return true;
  }

  void emit_class(Class* klass, int indent) {
    int node_start = pos(klass->full_range().from());
    int node_end = pos(klass->full_range().to());
    int first_member_line_start =
        find_line_start(pos(klass->members().first()->full_range().from()));

    // Try canonical AST-driven header (single-line if fits, broken
    // per-clause otherwise). Falls back to the verbatim re-indent path
    // when guards fail (comments, unreliable ranges).
    if (try_emit_class_header_canonical(klass, indent, first_member_line_start)) {
      // members and trailing bytes still emitted below.
    } else {
      // Header: re-indent and emit bytes up to (but not including) the
      // first member's leading whitespace. The member's own emit will
      // rewrite that.
      emit_range_reindent(node_start, first_member_line_start, indent);
    }

    for (auto member : klass->members()) {
      emit_decl(member, indent + INDENT_STEP);
    }

    advance_to(node_end);
  }

  // Renders a class / interface / monitor / mixin header from AST.
  // Single-line `[abstract] (class|...) Name [extends S] [with M...]
  // [implements I...]:` when it fits MAX_LINE_WIDTH; otherwise broken
  // with each clause on its own continuation line at indent +
  // CALL_CONTINUATION_STEP.
  //
  // Returns false when guards fail; caller falls back to verbatim
  // re-indent of the header bytes. Advances source_cursor_ to
  // `first_member_line_start` on success (so the members loop runs
  // unchanged in either path).
  bool try_emit_class_header_canonical(Class* klass, int indent,
                                       int first_member_line_start) {
    int node_start = pos(klass->full_range().from());
    if (klass->name() == nullptr) return false;
    if (has_line_locking_comment(node_start, first_member_line_start)) return false;
    if (has_interior_multiline_block_comment(node_start, first_member_line_start)) {
      return false;
    }
    int line_start = find_line_start(node_start);
    if (line_start < source_cursor_) return false;
    if (!is_leading_whitespace(line_start, node_start)) return false;
    if (!has_reliable_full_range(klass->name())) return false;
    if (klass->super() != nullptr && !has_reliable_full_range(klass->super())) {
      return false;
    }
    for (auto i : klass->interfaces()) {
      if (!has_reliable_full_range(i)) return false;
    }
    for (auto m : klass->mixins()) {
      if (!has_reliable_full_range(m)) return false;
    }

    // First-line prefix: `[abstract] (class|interface|monitor|mixin) Name`.
    std::string prefix;
    if (klass->has_abstract_modifier()) prefix.append("abstract ");
    switch (klass->kind()) {
      case Class::CLASS: prefix.append("class "); break;
      case Class::INTERFACE: prefix.append("interface "); break;
      case Class::MONITOR: prefix.append("monitor "); break;
      case Class::MIXIN: prefix.append("mixin "); break;
    }
    int n_start = pos(klass->name()->full_range().from());
    int n_end = pos(klass->name()->full_range().to());
    prefix.append(reinterpret_cast<const char*>(text_) + n_start, n_end - n_start);

    // Render each clause as a separate string.
    auto render_expr_bytes = [&](Expression* e) -> std::string {
      int s = pos(e->full_range().from());
      int t = pos(e->full_range().to());
      return std::string(reinterpret_cast<const char*>(text_) + s, t - s);
    };

    std::string extends_clause;
    if (klass->super() != nullptr) {
      extends_clause = "extends " + render_expr_bytes(klass->super());
    }
    std::string with_clause;
    if (!klass->mixins().is_empty()) {
      with_clause = "with";
      for (auto m : klass->mixins()) {
        with_clause += " " + render_expr_bytes(m);
      }
    }
    std::string implements_clause;
    if (!klass->interfaces().is_empty()) {
      implements_clause = "implements";
      for (auto i : klass->interfaces()) {
        implements_clause += " " + render_expr_bytes(i);
      }
    }

    // Try single-line render: prefix + clauses (space-separated) + ":".
    std::string single = prefix;
    if (!extends_clause.empty()) single += " " + extends_clause;
    if (!with_clause.empty()) single += " " + with_clause;
    if (!implements_clause.empty()) single += " " + implements_clause;
    single += ":";
    bool single_fits = indent + static_cast<int>(single.size()) <= MAX_LINE_WIDTH;

    int original_indent = node_start - line_start;
    int delta = indent - original_indent;
    emit_with_indent_shift(source_cursor_, line_start, delta);
    emit_spaces(indent);

    if (single_fits) {
      output_.append(single);
    } else {
      // Broken form: prefix on first line, each clause on its own
      // continuation line at indent + CALL_CONTINUATION_STEP, `:` at
      // the end of the last clause.
      output_.append(prefix);
      int continuation = indent + CALL_CONTINUATION_STEP;
      auto append_clause = [&](const std::string& clause) {
        output_.push_back('\n');
        output_.append(continuation, ' ');
        output_.append(clause);
      };
      if (!extends_clause.empty()) append_clause(extends_clause);
      if (!with_clause.empty()) append_clause(with_clause);
      if (!implements_clause.empty()) append_clause(implements_clause);
      output_.push_back(':');
    }
    output_.push_back('\n');
    source_cursor_ = first_member_line_start;
    return true;
  }

  void emit_method(Method* method, int indent) {
    // Render header + body fully from AST when possible (handles
    // single-stmt body inline-vs-broken, multi-stmt body, and
    // header normalisation). Falls back to the source-shape-
    // preserving paths when AST render can't cover the case.
    if (try_emit_method_full_canonical(method, indent)) return;
    if (try_emit_method_body_canonical(method, indent)) return;
    if (try_emit_method_canonical(method, indent)) return;
    if (!emit_with_suite(method, method->body()->expressions(), indent)) {
      emit_leaf(method, indent);
    }
  }

  // Renders a method (header + body) entirely from AST. Header gets
  // canonical single-spacing. Single-line if it fits MAX_LINE_WIDTH;
  // otherwise the parameters wrap to continuation lines (with the
  // `-> Type` annotation on the first line per existing convention).
  // Body emits inline `: body` if total fits INLINE_CONTROL_FLOW_WIDTH;
  // single-stmt broken `header:\n  body`; multi-stmt broken via
  // emit_stmt recursion. Abstract methods omit the body.
  //
  // Returns false on any unreliable range or layout shape that this
  // path doesn't cover (multi-stmt source-inline body, etc.) so the
  // caller can fall back to the source-shape-preserving path.
  bool try_emit_method_full_canonical(Method* method, int indent) {
    int node_start = pos(method->full_range().from());
    int node_end = pos(method->full_range().to());
    if (has_line_locking_comment(node_start, node_end)) return false;
    if (has_interior_multiline_block_comment(node_start, node_end)) return false;
    int line_start = find_line_start(node_start);
    if (line_start < source_cursor_) return false;
    if (!is_leading_whitespace(line_start, node_start)) return false;

    std::string header;
    if (!render_method_header(method, &header)) return false;

    bool header_single_line_fits = (indent + static_cast<int>(header.size())) <= MAX_LINE_WIDTH;
    if (!header_single_line_fits) {
      // TODO: render broken-header form (params on continuation lines).
      // For now, fall back so try_emit_method_canonical can re-indent
      // the source's wrapped params.
      return false;
    }

    Sequence* body_seq = method->body();
    bool has_body = body_seq != nullptr && !body_seq->expressions().is_empty();
    auto body = has_body ? body_seq->expressions() : List<Expression*>();

    // Pre-flight: decide which sub-path applies BEFORE touching
    // output_ or source_cursor_, so a bail doesn't leave partial
    // emission. Values populated below describe the chosen path.
    enum Path { ABSTRACT, INLINE_BODY, BROKEN_SYNTH_BODY,
                EMIT_STMT_BODY, MULTI_STMT_BODY };
    Path path = ABSTRACT;
    int body_indent = indent + INDENT_STEP;
    std::string body_buf;
    int body_first_line_start = -1;
    if (has_body) {
      if (body.length() == 1) {
        Expression* body_stmt = body.first();
        if (can_emit_flat(body_stmt)) {
          emit_expr_flat(body_stmt, PRECEDENCE_NONE, &body_buf);
          int inline_total = indent + static_cast<int>(header.size()) + 2
                           + static_cast<int>(body_buf.size());
          path = (inline_total <= INLINE_CONTROL_FLOW_WIDTH)
              ? INLINE_BODY : BROKEN_SYNTH_BODY;
        } else {
          // Source-byte path via emit_stmt — needs body on its own line.
          body_first_line_start =
              find_line_start(pos(body_stmt->full_range().from()));
          if (body_first_line_start <= node_start) return false;
          path = EMIT_STMT_BODY;
        }
      } else {
        body_first_line_start =
            find_line_start(pos(body.first()->full_range().from()));
        if (body_first_line_start <= node_start) return false;
        path = MULTI_STMT_BODY;
      }
    }

    // Commit: emit header.
    int original_indent = node_start - line_start;
    int delta = indent - original_indent;
    emit_with_indent_shift(source_cursor_, line_start, delta);
    emit_spaces(indent);
    output_.append(header);

    switch (path) {
      case ABSTRACT:
        // `abstract foo -> int` (no body) emits just header. A
        // non-abstract method with no body (`foo:`) keeps the `:`
        // separator to remain syntactically distinguishable.
        if (!method->is_abstract()) {
          output_.push_back(':');
          // Advance source_cursor_ past the source's `:` so we don't
          // emit it twice in the next stmt's leading trivia.
          int colon = node_end;
          while (colon < size_ && text_[colon] != ':' && text_[colon] != '\n') {
            colon++;
          }
          source_cursor_ = (colon < size_ && text_[colon] == ':')
                         ? colon + 1
                         : node_end;
        } else {
          source_cursor_ = node_end;
          // Block params: their closing `]` sits just past the
          // param's full_range. Advance past it so it doesn't
          // re-emit in subsequent trivia.
          if (!method->parameters().is_empty()
              && method->parameters().last()->is_block()
              && source_cursor_ < size_
              && text_[source_cursor_] == ']') {
            source_cursor_++;
          }
        }
        return true;
      case INLINE_BODY:
        output_.append(": ");
        output_.append(body_buf);
        source_cursor_ = node_end;
        return true;
      case BROKEN_SYNTH_BODY:
        // Body line may exceed MAX_LINE_WIDTH when body itself is
        // wide; accepted for determinism.
        output_.push_back(':');
        output_.push_back('\n');
        output_.append(body_indent, ' ');
        output_.append(body_buf);
        source_cursor_ = node_end;
        return true;
      case EMIT_STMT_BODY:
        output_.push_back(':');
        output_.push_back('\n');
        source_cursor_ = body_first_line_start;
        emit_stmt(body.first(), body_indent);
        source_cursor_ = node_end;
        return true;
      case MULTI_STMT_BODY:
        output_.push_back(':');
        output_.push_back('\n');
        source_cursor_ = body_first_line_start;
        for (auto stmt : body) {
          emit_stmt(stmt, body_indent);
        }
        source_cursor_ = node_end;
        return true;
    }
    return true;
  }

  // Locates the body-separator `:` between `method_start` and the
  // body's first byte. Returns -1 if not found, or if the search range
  // contains a newline (header is multi-line in source — caller
  // should bail).
  // Renders a single Parameter (block / lambda or method/constructor
  // signature parameter) into `out`. Form:
  //
  //   [`[`] [`--`] [`.`] name [`/`Type] [`=`default] [`]`]
  //
  // The `[ ... ]` brackets surround block parameters (`is_block`).
  // `--` for named, `.` for field-storing constructor params.
  bool render_parameter(Parameter* p, std::string* out) {
    if (p->name() == nullptr) return false;
    if (!has_reliable_full_range(p->name())) return false;
    if (p->type() != nullptr && !can_emit_flat(p->type())) return false;
    if (p->default_value() != nullptr && !can_emit_flat(p->default_value())) {
      return false;
    }
    if (p->is_block()) out->push_back('[');
    if (p->is_named()) out->append("--");
    if (p->is_field_storing()) out->push_back('.');
    int n_start = pos(p->name()->full_range().from());
    int n_end = pos(p->name()->full_range().to());
    out->append(reinterpret_cast<const char*>(text_) + n_start, n_end - n_start);
    if (p->type() != nullptr) {
      out->push_back('/');
      emit_expr_flat(p->type(), PRECEDENCE_POSTFIX, out);
    }
    if (p->default_value() != nullptr) {
      out->push_back('=');
      emit_expr_flat(p->default_value(), PRECEDENCE_POSTFIX, out);
    }
    if (p->is_block()) out->push_back(']');
    return true;
  }

  // Renders the method header (everything before the body separator
  // `:`) into `out`. Form:
  //
  //   [abstract ] [static ] (name|Type.named) [params] [-> ReturnType]
  //
  // Setter methods get `=` appended to the name. Returns false on
  // any unreliable range so caller can fall back.
  bool render_method_header(Method* method, std::string* out) {
    if (method->name_or_dot() == nullptr) return false;
    if (method->is_abstract()) out->append("abstract ");
    if (method->is_static()) out->append("static ");
    Expression* name_or_dot = method->name_or_dot();
    if (name_or_dot->is_Dot()) {
      Dot* d = name_or_dot->as_Dot();
      if (!has_reliable_full_range(d->receiver())) return false;
      if (!has_reliable_full_range(d->name())) return false;
      // d->receiver() is `Type` (Identifier), d->name() is `named`.
      int rs = pos(d->receiver()->full_range().from());
      int re = pos(d->receiver()->full_range().to());
      out->append(reinterpret_cast<const char*>(text_) + rs, re - rs);
      out->push_back('.');
      int ns = pos(d->name()->full_range().from());
      int ne = pos(d->name()->full_range().to());
      out->append(reinterpret_cast<const char*>(text_) + ns, ne - ns);
    } else if (name_or_dot->is_Identifier()) {
      if (!has_reliable_full_range(name_or_dot)) return false;
      int ns = pos(name_or_dot->full_range().from());
      int ne = pos(name_or_dot->full_range().to());
      out->append(reinterpret_cast<const char*>(text_) + ns, ne - ns);
    } else {
      return false;
    }
    if (method->is_setter()) out->push_back('=');
    for (auto p : method->parameters()) {
      out->push_back(' ');
      if (!render_parameter(p, out)) return false;
    }
    if (method->return_type() != nullptr) {
      if (!can_emit_flat(method->return_type())) return false;
      out->append(" -> ");
      emit_expr_flat(method->return_type(), PRECEDENCE_POSTFIX, out);
    }
    return true;
  }

  // Locates the body-separator `:` between `node_start` and the
  // body's first byte. Returns -1 if not found, or if the header
  // (everything between `node_start` and the colon) spans multiple
  // lines.
  //
  // Walks backward from `body_start`: the body separator `:` is the
  // last `:` before the body, modulo trailing whitespace (and a
  // single newline + indent for source-broken bodies). This avoids
  // misidentifying `:` inside string literals or `:=` / `::` / `::=`
  // combinators in the header. After finding the colon, we verify
  // the header itself (`node_start..colon_pos`) is single-line,
  // since the byte-header canonical emits the header bytes verbatim
  // and would otherwise emit a multi-line span on what should be
  // one line.
  int find_node_header_colon(int node_start, int body_start) const {
    int i = body_start - 1;
    bool seen_newline = false;
    int colon_pos = -1;
    while (i >= node_start) {
      uint8 c = text_[i];
      if (c == ' ' || c == '\t' || c == '\r') {
        i--;
        continue;
      }
      if (c == '\n') {
        if (seen_newline) return -1;  // body more than one line below
        seen_newline = true;
        i--;
        continue;
      }
      if (c == ':') { colon_pos = i; break; }
      return -1;  // unexpected non-whitespace before body
    }
    if (colon_pos < 0) return -1;
    // Header must be single-line: no newlines between node_start and
    // colon_pos.
    for (int j = node_start; j < colon_pos; j++) {
      if (text_[j] == '\n') return -1;
    }
    return colon_pos;
  }

  // Inline-vs-broken canonicalisation for a node with a single-stmt
  // body separated from a complex header by `:`. Used by Method bodies
  // and `for init; cond; update: body` — both have headers too varied
  // to render from AST, so the header is byte-copied verbatim
  // (must be single-line) and only the body is rendered from AST.
  //
  // Inline `header: body` when the rendered total fits
  // INLINE_CONTROL_FLOW_WIDTH; broken `header:\n  body` when inline
  // doesn't fit but the body itself fits at body_indent under
  // MAX_LINE_WIDTH; otherwise bails (caller falls back to the
  // existing source-shape-preserving path).
  bool try_emit_byte_header_body_canonical(int node_start, int node_end,
                                           List<Expression*> body,
                                           int indent) {
    if (body.length() != 1) return false;
    Expression* body_stmt = body.first();
    if (!can_emit_flat(body_stmt)) return false;

    if (has_line_locking_comment(node_start, node_end)) return false;
    if (has_interior_multiline_block_comment(node_start, node_end)) return false;

    int line_start = find_line_start(node_start);
    if (line_start < source_cursor_) return false;
    if (!is_leading_whitespace(line_start, node_start)) return false;

    int body_start = pos(body_stmt->full_range().from());
    int colon_pos = find_node_header_colon(node_start, body_start);
    if (colon_pos < 0) return false;  // header multi-line, bail.
    int header_len = colon_pos - node_start;

    std::string body_buf;
    emit_expr_flat(body_stmt, PRECEDENCE_NONE, &body_buf);
    int inline_total = indent + header_len + 2 + static_cast<int>(body_buf.size());
    int original_indent = node_start - line_start;
    int delta = indent - original_indent;

    if (inline_total <= INLINE_CONTROL_FLOW_WIDTH) {
      emit_with_indent_shift(source_cursor_, line_start, delta);
      emit_spaces(indent);
      output_.append(reinterpret_cast<const char*>(text_) + node_start, header_len);
      output_.append(": ");
      output_.append(body_buf);
      source_cursor_ = node_end;
      return true;
    }

    int body_indent = indent + INDENT_STEP;
    if (body_indent + static_cast<int>(body_buf.size()) > MAX_LINE_WIDTH) {
      return false;
    }
    emit_with_indent_shift(source_cursor_, line_start, delta);
    emit_spaces(indent);
    output_.append(reinterpret_cast<const char*>(text_) + node_start, header_len);
    output_.push_back(':');
    output_.push_back('\n');
    output_.append(body_indent, ' ');
    output_.append(body_buf);
    source_cursor_ = node_end;
    return true;
  }

  bool try_emit_method_body_canonical(Method* method, int indent) {
    if (method->body() == null) return false;
    return try_emit_byte_header_body_canonical(
        pos(method->full_range().from()),
        pos(method->full_range().to()),
        method->body()->expressions(),
        indent);
  }

  bool try_emit_for_canonical(For* f, int indent) {
    auto body = as_suite_body(f->body());
    if (body.is_empty()) return false;
    return try_emit_byte_header_body_canonical(
        pos(f->full_range().from()),
        pos(f->full_range().to()),
        body,
        indent);
  }

  // If a Method has parameters on their own continuation lines (rather
  // than all on the method's first line), re-indent each continuation
  // parameter to `indent + CALL_CONTINUATION_STEP`. Then recurse into the
  // body at indent + INDENT_STEP.
  //
  // Returns false if there are no continuation parameters, or guards
  // fail — caller falls back to emit_with_suite (which handles the
  // all-params-on-one-line case).
  bool try_emit_method_canonical(Method* method, int indent) {
    if (method->body() == null || method->body()->expressions().is_empty()) {
      return false;
    }
    int method_start = pos(method->full_range().from());
    int method_end = pos(method->full_range().to());
    if (has_line_locking_comment(method_start, method_end)) return false;
    for (auto param : method->parameters()) {
      if (!has_reliable_full_range(param)) return false;
    }

    int method_line_start = find_line_start(method_start);
    if (method_line_start < source_cursor_) return false;
    if (!is_leading_whitespace(method_line_start, method_start)) return false;

    int first_break = -1;
    for (int i = 0; i < method->parameters().length(); i++) {
      int param_line =
          find_line_start(pos(method->parameters()[i]->full_range().from()));
      if (param_line > method_line_start) {
        first_break = i;
        break;
      }
    }
    if (first_break < 0) return false;

    auto body_exprs = method->body()->expressions();
    int body_first_line_start =
        find_line_start(pos(body_exprs.first()->full_range().from()));
    if (body_first_line_start <= method_line_start) return false;

    int continuation_indent = indent + CALL_CONTINUATION_STEP;
    Expression* return_type = method->return_type();

    if (return_type != null && has_reliable_full_range(return_type)) {
      // Wrapped-param method with a return type: keep `-> Type` on the
      // first line next to the name (and any same-line params); put `:`
      // at the end of the last continuation param.
      //
      // Compute "end of the first-line content": if the source already
      // has `-> Type` on the method's first line, we stop at the `->`
      // position so we don't double-emit the arrow below. Otherwise we
      // stop at the first newline. Either way, strip trailing spaces so
      // `" -> "` appends cleanly. Using the raw line range (rather than
      // the last first-line param's full_range) handles block-param
      // brackets and similar syntactic decorations that sit outside the
      // AST node's range.
      int first_newline = method_start;
      while (first_newline < size_ && text_[first_newline] != '\n') {
        first_newline++;
      }
      int arrow_on_first_line = -1;
      for (int i = method_start; i + 1 < first_newline; i++) {
        if (text_[i] == '-' && text_[i + 1] == '>') {
          arrow_on_first_line = i;
          break;
        }
      }
      int first_line_content_end = arrow_on_first_line >= 0
                                 ? arrow_on_first_line
                                 : first_newline;
      while (first_line_content_end > method_start
             && (text_[first_line_content_end - 1] == ' '
                 || text_[first_line_content_end - 1] == '\t')) {
        first_line_content_end--;
      }

      emit_range_reindent(method_start, first_line_content_end, indent);
      output_.append(" -> ");
      int rt_start = pos(return_type->full_range().from());
      int rt_end = pos(return_type->full_range().to());
      output_.append(reinterpret_cast<const char*>(text_) + rt_start,
                     rt_end - rt_start);
      source_cursor_ = rt_end;

      for (int i = first_break; i < method->parameters().length(); i++) {
        auto param = method->parameters()[i];
        int p_start = pos(param->full_range().from());
        int p_end = pos(param->full_range().to());
        // Block-parameter brackets — `[--on-absent]` — sit just outside
        // Parameter's full_range. Extend the emission range to include
        // an adjacent `[` and/or `]` so they survive the rewrite.
        if (p_start > 0 && text_[p_start - 1] == '[') p_start--;
        if (p_end < size_ && text_[p_end] == ']') p_end++;
        output_.push_back('\n');
        output_.append(continuation_indent, ' ');
        output_.append(reinterpret_cast<const char*>(text_) + p_start,
                       p_end - p_start);
        source_cursor_ = p_end;
      }
      output_.push_back(':');
      // Advance past the source's header-closing `:` so the upcoming
      // advance_to(body_first_line_start) doesn't double-emit it. Scan
      // inclusive of source_cursor_: the `:` often sits flush against
      // the last param, i.e. at position source_cursor_ itself.
      int colon_pos = body_first_line_start - 1;
      while (colon_pos >= source_cursor_ && text_[colon_pos] != ':') {
        colon_pos--;
      }
      if (colon_pos >= source_cursor_ && text_[colon_pos] == ':') {
        source_cursor_ = colon_pos + 1;
      }
    } else {
      int break_line_start = find_line_start(
          pos(method->parameters()[first_break]->full_range().from()));
      emit_range_reindent(method_start, break_line_start, indent);

      for (int i = first_break; i < method->parameters().length(); i++) {
        auto param = method->parameters()[i];
        emit_range_reindent(pos(param->full_range().from()),
                            pos(param->full_range().to()),
                            continuation_indent);
      }
    }

    // Remainder of the header — return type annotation if any, `:`, newline
    // — is emitted verbatim up to the first body line.
    advance_to(body_first_line_start);

    for (auto expr : body_exprs) {
      emit_stmt(expr, indent + INDENT_STEP);
    }

    advance_to(method_end);
    return true;
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
    if (options_.force_flat && emit_stmt_flat(stmt, indent, -1)) return;

    // Normal-mode flat-if-fits. Bare Call has its own source-byte flat
    // path (try_emit_call_flat_canonical, less paren-happy), and control-
    // flow nodes aren't flat-emittable, so skip those here — the rest
    // (Binary, Dot, Unary, Index, literals, Return/DeclLocal wrapping
    // these, etc.) benefit from collapsing when the flat form fits.
    if (!stmt->is_Call() && !stmt->is_If() && !stmt->is_While()
        && !stmt->is_For() && !stmt->is_TryFinally()
        && emit_stmt_flat(stmt, indent, stmt_width_budget(stmt))) {
      return;
    }

    if (stmt->is_Call()) {
      emit_call(stmt->as_Call(), indent);
      return;
    }
    if (stmt->is_If()) {
      // Inline / broken-synth canonicalisation runs before emit_if so
      // that source-broken short Ifs become inline and source-inline
      // long Ifs become broken — output is a function of (AST + width),
      // not of the source's choice of layout.
      if (try_emit_if_canonical(stmt->as_If(), indent)) return;
      if (emit_if(stmt->as_If(), indent)) return;
    } else if (stmt->is_While()) {
      if (try_emit_while_canonical(stmt->as_While(), indent)) return;
      auto body = as_suite_body(stmt->as_While()->body());
      if (!body.is_empty() && emit_with_suite(stmt, body, indent)) return;
    } else if (stmt->is_For()) {
      if (try_emit_for_canonical(stmt->as_For(), indent)) return;
      auto body = as_suite_body(stmt->as_For()->body());
      if (!body.is_empty() && emit_with_suite(stmt, body, indent)) return;
    } else if (stmt->is_TryFinally()) {
      if (try_emit_try_finally_canonical(stmt->as_TryFinally(), indent)) return;
      if (emit_try_finally(stmt->as_TryFinally(), indent)) return;
    }

    // `return <call>` / `x := <call>` / `x = <call>` wrappers: either
    // canonicalize the continuation indent of an already-broken Call, or
    // synthesize a break when the whole wrapper exceeds MAX_LINE_WIDTH on
    // a single line.
    if (stmt->is_Return()) {
      auto ret = stmt->as_Return();
      if (ret->value() != null && ret->value()->is_Call()) {
        Call* call = ret->value()->as_Call();
        int start = pos(ret->full_range().from());
        int end = pos(ret->full_range().to());
        if (try_emit_call_trailing_block_inline(call, start, end, indent)) return;
        if (try_canonicalize_broken_call_in_range(call, start, end, indent)) return;
        if (emit_call_forced_broken(call, start, end, indent)) return;
      }
    }
    if (stmt->is_DeclarationLocal()) {
      auto decl = stmt->as_DeclarationLocal();
      if (decl->value() != null && decl->value()->is_Call()) {
        Call* call = decl->value()->as_Call();
        int start = pos(decl->full_range().from());
        int end = pos(decl->full_range().to());
        if (try_emit_call_trailing_block_inline(call, start, end, indent)) return;
        if (try_canonicalize_broken_call_in_range(call, start, end, indent)) return;
        if (emit_call_forced_broken(call, start, end, indent)) return;
      }
    }
    if (stmt->is_Binary()) {
      Binary* b = stmt->as_Binary();
      if (Token::precedence(b->kind()) == PRECEDENCE_ASSIGNMENT
          && b->right() != null && b->right()->is_Call()) {
        Call* call = b->right()->as_Call();
        int start = pos(b->full_range().from());
        int end = pos(b->full_range().to());
        if (try_emit_call_trailing_block_inline(call, start, end, indent)) return;
        if (try_canonicalize_broken_call_in_range(call, start, end, indent)) return;
        if (emit_call_forced_broken(call, start, end, indent)) return;
      }
    }

    // Many-element collection literal as the stmt's value gets a
    // synthesised per-line broken form.
    if (try_emit_stmt_force_broken_collection(stmt, indent)) return;

    // Too-wide Binary chain gets split across lines at operator
    // boundaries.
    if (try_emit_binary_forced_broken(stmt, indent)) return;

    emit_leaf(stmt, indent);
  }

  // Flat-mode emission of a statement-position expression. Re-indents the
  // first line to `indent` and writes the expression's canonical flat
  // form, with parens inserted around nested expressions where necessary
  // to keep the re-parsed AST equivalent.
  //
  // Returns false when we don't know how to flatten this expression
  // safely — the caller falls back to verbatim leaf emission.
  // Flat-if-fits emission. `max_width < 0` means unlimited (force_flat CI
  // mode where we just care about AST equivalence). `max_width >= 0` caps
  // the rendered width to the given column; too-wide output returns false
  // and caller falls back to broken/verbatim paths.
  bool emit_stmt_flat(Expression* stmt, int indent, int max_width) {
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
    // Render first so we can bail on width before committing any output.
    std::string buffer;
    emit_expr_flat(stmt, PRECEDENCE_NONE, &buffer);
    if (max_width >= 0 && indent + static_cast<int>(buffer.size()) > max_width) {
      return false;
    }

    int original_indent = start - line_start;
    int delta = indent - original_indent;
    emit_with_indent_shift(source_cursor_, line_start, delta);
    emit_spaces(indent);
    source_cursor_ = end;
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

  // Toit's parser groups `a and b and c` as `a and (b and c)` (parser.cc
  // explicitly notes logical operations are right-associative). Assignment
  // ops (`=`, `:=`, `+=`, ...) are likewise right-assoc. Everything else
  // (arithmetic, comparison, bit ops, shift) is left-assoc.
  static bool is_right_assoc_binary(Token::Kind k) {
    int p = Token::precedence(k);
    return p == PRECEDENCE_AND || p == PRECEDENCE_OR
        || p == PRECEDENCE_ASSIGNMENT;
  }

  // Renders the receiver of a Dot / Index / IndexSlice. Preserves any
  // source Parenthesis around the receiver — that's the author's
  // explicit `(Foo).bar` (instance access on a class object) — but
  // doesn't synthesise parens around bare Identifier receivers. Without
  // a resolver we can't tell `Foo.bar` (named constructor / static
  // call) from `(Foo).bar` (method on the class object), so we honour
  // what the source had.
  void emit_receiver(Expression* recv, std::string* out) {
    if (recv == null) return;
    if (recv->is_Parenthesis()) {
      out->append("(");
      Expression* inner = recv->as_Parenthesis()->expression();
      while (inner != null && inner->is_Parenthesis()) {
        inner = inner->as_Parenthesis()->expression();
      }
      emit_expr_flat(inner, PRECEDENCE_NONE, out);
      out->append(")");
      return;
    }
    emit_expr_flat(recv, PRECEDENCE_POSTFIX, out);
  }

  // Is `e` a collection literal (List / Map / Set / ByteArray)?
  static bool is_collection_literal(Expression* e) {
    return e != null
        && (e->is_LiteralList() || e->is_LiteralSet()
            || e->is_LiteralMap() || e->is_LiteralByteArray());
  }

  // Config-call heuristic: a Call with three or more NamedArguments gets
  // a tighter width budget. Breaking such Calls per-line is a legibility
  // win in its own right (each option on its own line), not a space-
  // saving compromise — so even flat forms that would fit under the
  // standard 100-col limit get broken when they cross the config-call
  // threshold.
  static int named_arg_count(Call* c) {
    int n = 0;
    for (auto a : c->arguments()) if (a->is_NamedArgument()) n++;
    return n;
  }

  static bool is_config_call(Call* c) {
    return named_arg_count(c) >= NAMED_ARG_CALL_MIN;
  }

  static int call_width_budget(Call* c) {
    return is_config_call(c) ? NAMED_ARG_CALL_WIDTH : MAX_LINE_WIDTH;
  }

  // Effective width budget for this statement. Defaults to MAX_LINE_WIDTH
  // but tightens to NAMED_ARG_CALL_WIDTH when the stmt's value (or a
  // wrapper chain around it) ends in a config-call Call. Walks through
  // Return, DeclarationLocal, and assignment Binary wrappers but doesn't
  // recurse into Call args, Binary operands, or collection elements —
  // a config-call sitting deep inside some other expression doesn't
  // tighten the outer stmt's budget.
  int stmt_width_budget(Expression* stmt) const {
    Expression* v = stmt;
    if (stmt->is_Return()) v = stmt->as_Return()->value();
    else if (stmt->is_DeclarationLocal()) v = stmt->as_DeclarationLocal()->value();
    else if (stmt->is_Binary()) {
      auto b = stmt->as_Binary();
      if (Token::precedence(b->kind()) == PRECEDENCE_ASSIGNMENT) {
        v = b->right();
      }
    }
    while (v != null && v->is_Parenthesis()) {
      v = v->as_Parenthesis()->expression();
    }
    if (v != null && v->is_Call() && is_config_call(v->as_Call())) {
      return NAMED_ARG_CALL_WIDTH;
    }
    return MAX_LINE_WIDTH;
  }

  // For a statement shaped as `<collection>`, `return <collection>`,
  // `x := <collection>` or `x = <collection>`, returns the collection
  // sub-expression. Returns null otherwise. Parenthesis-wrapped
  // collections aren't handled here — they fall through to verbatim.
  Expression* find_force_break_collection(Expression* stmt) const {
    if (is_collection_literal(stmt)) return stmt;
    if (stmt->is_Return()) {
      auto v = stmt->as_Return()->value();
      if (is_collection_literal(v)) return v;
    }
    if (stmt->is_DeclarationLocal()) {
      auto v = stmt->as_DeclarationLocal()->value();
      if (is_collection_literal(v)) return v;
    }
    if (stmt->is_Binary()) {
      auto b = stmt->as_Binary();
      if (Token::precedence(b->kind()) == PRECEDENCE_ASSIGNMENT
          && is_collection_literal(b->right())) {
        return b->right();
      }
    }
    return null;
  }

  // Walks a same-operator Binary chain and collects its operands in
  // left-to-right order. Stops at the first child of the chain's own
  // kind that is wrapped in Parenthesis or that uses a different
  // operator — those nodes become single operands.
  void flatten_binary_chain(Binary* b, Token::Kind op,
                            std::vector<Expression*>* operands) const {
    if (is_right_assoc_binary(op)) {
      operands->push_back(b->left());
      Expression* r = b->right();
      if (r != null && !r->is_Parenthesis()
          && r->is_Binary() && r->as_Binary()->kind() == op) {
        flatten_binary_chain(r->as_Binary(), op, operands);
      } else {
        operands->push_back(r);
      }
    } else {
      Expression* l = b->left();
      if (l != null && !l->is_Parenthesis()
          && l->is_Binary() && l->as_Binary()->kind() == op) {
        flatten_binary_chain(l->as_Binary(), op, operands);
      } else {
        operands->push_back(l);
      }
      operands->push_back(b->right());
    }
  }

  // For a statement shaped as `<binary>`, `return <binary>`,
  // `x := <binary>` or `x = <binary>`, returns the Binary that should be
  // force-broken (its chain distributed across lines) when the stmt is
  // over the width budget. Returns null if there's nothing broken-breakable
  // at the top (e.g. the value is a Call, a literal, an assignment, etc.).
  Binary* find_force_break_binary(Expression* stmt) const {
    Expression* v = null;
    if (stmt->is_Return()) {
      v = stmt->as_Return()->value();
    } else if (stmt->is_DeclarationLocal()) {
      v = stmt->as_DeclarationLocal()->value();
    } else if (stmt->is_Binary()) {
      auto b = stmt->as_Binary();
      if (Token::precedence(b->kind()) == PRECEDENCE_ASSIGNMENT) {
        v = b->right();
      } else {
        v = stmt;  // bare Binary stmt.
      }
    } else {
      v = stmt;
    }
    while (v != null && v->is_Parenthesis()) {
      v = v->as_Parenthesis()->expression();
    }
    if (v == null || !v->is_Binary()) return null;
    if (Token::precedence(v->as_Binary()->kind()) == PRECEDENCE_ASSIGNMENT) {
      return null;  // don't mess with nested assignments
    }
    return v->as_Binary();
  }

  // Whether `e` contains a Call anywhere in its expression tree. Used
  // to decide whether a Binary arg of an outer Call needs defensive
  // parens — if the Binary embeds a Call, greedy Call parsing would
  // absorb that inner target into the outer Call's arg list instead.
  static bool contains_call(Expression* e) {
    if (e == null) return false;
    if (e->is_Call()) return true;
    if (e->is_Parenthesis()) {
      return contains_call(e->as_Parenthesis()->expression());
    }
    if (e->is_Unary()) return contains_call(e->as_Unary()->expression());
    if (e->is_Binary()) {
      auto b = e->as_Binary();
      return contains_call(b->left()) || contains_call(b->right());
    }
    if (e->is_Dot()) return contains_call(e->as_Dot()->receiver());
    if (e->is_Index()) {
      auto idx = e->as_Index();
      if (contains_call(idx->receiver())) return true;
      for (auto a : idx->arguments()) {
        if (contains_call(a)) return true;
      }
      return false;
    }
    if (e->is_NamedArgument()) {
      return contains_call(e->as_NamedArgument()->expression());
    }
    return false;
  }

  static bool is_bitwise_binary(Token::Kind k) {
    int p = Token::precedence(k);
    return p == PRECEDENCE_BIT_SHIFT
        || p == PRECEDENCE_BIT_AND
        || p == PRECEDENCE_BIT_OR
        || p == PRECEDENCE_BIT_XOR;
  }

  // Whether a Binary whose operator is `child_kind`, sitting directly
  // beneath a Binary whose operator is `parent_kind`, should be wrapped
  // in clarifying parens even if precedence/associativity don't require
  // it. Rule of thumb: once bitwise operators enter the mix, readers
  // stop trusting the precedence table, so make the grouping explicit.
  static bool needs_bitwise_clarity(Token::Kind parent_kind,
                                    Token::Kind child_kind) {
    bool parent_bw = is_bitwise_binary(parent_kind);
    bool child_bw = is_bitwise_binary(child_kind);
    if (!parent_bw && !child_bw) return false;
    // ASSIGN is a statement-level boundary — its RHS doesn't need
    // defensive bitwise parens (`x = a & b` reads fine, no need for
    // `x = (a & b)`).
    if (Token::precedence(parent_kind) == PRECEDENCE_ASSIGNMENT) {
      return false;
    }
    // Same operator on both sides (e.g. `a & b & c`) reads unambiguously
    // as a chain — no parens needed.
    if (parent_kind == child_kind) return false;
    return true;
  }

  // Emits a Binary's child operand with the usual flat-form rules, plus
  // the bitwise-clarity override: when a bitwise op meets a different
  // op across a Binary/Binary boundary, wrap the child in parens. User-
  // provided Parenthesis wrappers go through emit_expr_flat unchanged.
  void emit_binary_child(Expression* child, int outer_prec,
                         Token::Kind parent_kind, std::string* out) {
    if (child != null && !child->is_Parenthesis() && child->is_Binary()) {
      Token::Kind child_kind = child->as_Binary()->kind();
      if (needs_bitwise_clarity(parent_kind, child_kind)) {
        out->append("(");
        emit_expr_flat(child, PRECEDENCE_NONE, out);
        out->append(")");
        return;
      }
    }
    emit_expr_flat(child, outer_prec, out);
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

  // Whether the inner of a Parenthesis wrapper is "trivial" enough that
  // the parens add nothing — a bare identifier or literal. For those, `(x)`
  // → `x`. Anything with structure (Binary, Unary, Call, Index, etc.) is
  // treated as the author's explicit grouping and preserved.
  static bool is_trivial_inner(Expression* e) {
    if (e == null) return false;
    return e->is_Identifier()
        || e->is_LiteralNull()
        || e->is_LiteralUndefined()
        || e->is_LiteralBoolean()
        || e->is_LiteralInteger()
        || e->is_LiteralCharacter()
        || e->is_LiteralFloat()
        || e->is_LiteralString();
  }

  void emit_expr_flat(Expression* expr, int outer_prec, std::string* out) {
    // Preserve user-provided grouping parens around non-trivial sub-
    // expressions. This keeps clarifying parens the author wrote
    // deliberately — most importantly for bitwise operators mixed with
    // other ops (`(byte >> 4) & mask`), where users typically don't
    // remember the precedence table. `(x)` around a bare identifier /
    // literal is still peeled as pure noise.
    while (expr != null && expr->is_Parenthesis()) {
      Expression* inner = expr->as_Parenthesis()->expression();
      if (is_trivial_inner(peel_parens(inner))) {
        expr = peel_parens(inner);
      } else {
        out->append("(");
        emit_expr_flat(inner, PRECEDENCE_NONE, out);
        out->append(")");
        return;
      }
    }
    if (expr->is_Binary()) {
      Binary* b = expr->as_Binary();
      int prec = Token::precedence(b->kind());
      bool parens = prec <= outer_prec && outer_prec != PRECEDENCE_NONE;
      if (parens) out->append("(");
      // Associativity: same-precedence children don't need parens on the
      // side the operator associates towards (right for right-assoc, left
      // for left-assoc). On the opposite side they do, to preserve the
      // AST's grouping.
      bool right_assoc = is_right_assoc_binary(b->kind());
      int left_prec = right_assoc ? prec : (prec - 1);
      int right_prec = right_assoc ? (prec - 1) : prec;
      // Assignment-precedence defines a stmt-level boundary on the right
      // side: nothing further right can bind into the RHS via Toit's
      // greedy Call parsing, so a Call or Binary there doesn't need the
      // defensive parens that `outer_prec != NONE` would normally force.
      // (`x = foo a b` stays `x = foo a b`, not `x = (foo a b)`.)
      if (prec == PRECEDENCE_ASSIGNMENT) right_prec = PRECEDENCE_NONE;
      // `or` / `and` parse each operand through parse_logical_spelled
      // → parse_not_spelled → parse_call directly (no Pratt climbing),
      // so both sides are stmt-level boundaries: a bare Call on either
      // side parses unambiguously, no defensive parens needed.
      if (prec == PRECEDENCE_OR || prec == PRECEDENCE_AND) {
        left_prec = PRECEDENCE_NONE;
        right_prec = PRECEDENCE_NONE;
      }
      emit_binary_child(b->left(), left_prec, b->kind(), out);
      out->append(" ");
      out->append(Token::symbol(b->kind()).c_str());
      out->append(" ");
      emit_binary_child(b->right(), right_prec, b->kind(), out);
      if (parens) out->append(")");
      return;
    }
    if (expr->is_Unary()) {
      Unary* u = expr->as_Unary();
      // Only the keyword `not` requires defensive parens in a non-NONE
      // context: `foo not x` is a parse error (Toit forbids `not` there),
      // while `foo (not x)` is fine. Every other unary operator is a
      // tight punctuation token (`-x`, `~x`, `x++`, `x--`), which binds
      // to its operand and doesn't collide with Toit's greedy Call. So
      // `foo -x y` parses as `Call(foo, [-x, y])` unchanged.
      bool parens = (u->kind() == Token::NOT && outer_prec != PRECEDENCE_NONE);
      if (parens) out->append("(");
      const char* op = Token::symbol(u->kind()).c_str();
      if (u->prefix()) {
        out->append(op);
        // `not` is a keyword, separate with a space; punctuation operators stay glued.
        if (u->kind() == Token::NOT) out->append(" ");
        // `not` is parsed via parse_not_spelled → parse_call directly,
        // so its operand is at a stmt-level boundary — a Call there
        // doesn't need defensive parens (`not foo a b`, not
        // `not (foo a b)`). Other prefix unaries (`-x`, `~x`) go
        // through parse_precedence(PRECEDENCE_POSTFIX), so their
        // operand stays at POSTFIX.
        int operand_prec = (u->kind() == Token::NOT)
                         ? PRECEDENCE_NONE
                         : PRECEDENCE_POSTFIX;
        emit_expr_flat(u->expression(), operand_prec, out);
      } else {
        emit_expr_flat(u->expression(), PRECEDENCE_POSTFIX, out);
        out->append(op);
      }
      if (parens) out->append(")");
      return;
    }
    if (expr->is_Dot()) {
      Dot* d = expr->as_Dot();
      emit_receiver(d->receiver(), out);
      out->append(".");
      // Dot's name is an Identifier — append its source bytes directly.
      int nfrom = pos(d->name()->full_range().from());
      int nto = pos(d->name()->full_range().to());
      out->append(reinterpret_cast<const char*>(text_) + nfrom, nto - nfrom);
      return;
    }
    if (expr->is_Index()) {
      Index* idx = expr->as_Index();
      emit_receiver(idx->receiver(), out);
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
      emit_receiver(slice->receiver(), out);
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
      // Opinionated rule for Binary args (whether the source wrote them
      // bare or wrapped in Parenthesis): single-arg Call emits the
      // Binary bare (`ByteArray end - start`), multi-arg Call wraps the
      // Binary so argument boundaries stay visible (`foo (a + b) c d`).
      // Low-precedence right-assoc ops (`and`, `or`, assignment) and
      // Binaries that embed a Call always need parens for AST safety.
      bool multi_arg = c->arguments().length() >= 2;
      for (auto arg : c->arguments()) {
        out->append(" ");
        // Peel Parenthesis to find the real shape of the arg. Users may
        // have written `(a + b)` or just `a + b` in source; the
        // formatter picks one rendering regardless.
        Expression* inner = arg;
        while (inner != null && inner->is_Parenthesis()) {
          inner = inner->as_Parenthesis()->expression();
        }
        if (inner != null && inner->is_Binary()) {
          Token::Kind k = inner->as_Binary()->kind();
          int p = Token::precedence(k);
          bool must_paren = (p <= PRECEDENCE_ASSIGNMENT)
                         || contains_call(inner)
                         || multi_arg;
          if (must_paren) {
            out->append("(");
            emit_expr_flat(inner, PRECEDENCE_NONE, out);
            out->append(")");
          } else {
            emit_expr_flat(inner, PRECEDENCE_NONE, out);
          }
        } else {
          emit_expr_flat(arg, PRECEDENCE_POSTFIX, out);
        }
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

  // Canonical broken-form emission for TryFinally, from AST. Same
  // shape as the if/else broken-synth: try / finally always emit
  // broken (per-stmt body and handler), regardless of source layout.
  // Inline `try: foo finally: bar` is never produced — three semantic
  // chunks on one line is hard to read, like `if A: a else: b`.
  bool try_emit_try_finally_canonical(TryFinally* tf, int indent) {
    auto body = tf->body() == null
        ? List<Expression*>()
        : tf->body()->expressions();
    auto handler = tf->handler() == null
        ? List<Expression*>()
        : tf->handler()->expressions();
    if (body.is_empty() || handler.is_empty()) return false;

    int node_start = pos(tf->full_range().from());
    int node_end = pos(tf->full_range().to());
    if (has_line_locking_comment(node_start, node_end)) return false;
    if (has_interior_multiline_block_comment(node_start, node_end)) return false;

    int line_start = find_line_start(node_start);
    if (line_start < source_cursor_) return false;
    if (!is_leading_whitespace(line_start, node_start)) return false;

    for (auto e : body) {
      if (!can_emit_flat(e)) return false;
    }
    for (auto e : handler) {
      if (!can_emit_flat(e)) return false;
    }

    int original_indent = node_start - line_start;
    int delta = indent - original_indent;
    emit_with_indent_shift(source_cursor_, line_start, delta);

    int body_indent = indent + INDENT_STEP;
    output_.append(indent, ' ');
    output_.append("try:");
    for (auto e : body) {
      output_.push_back('\n');
      output_.append(body_indent, ' ');
      std::string buf;
      emit_expr_flat(e, PRECEDENCE_NONE, &buf);
      output_.append(buf);
    }
    output_.push_back('\n');
    output_.append(indent, ' ');
    output_.append("finally:");
    for (auto e : handler) {
      output_.push_back('\n');
      output_.append(body_indent, ' ');
      std::string buf;
      emit_expr_flat(e, PRECEDENCE_NONE, &buf);
      output_.append(buf);
    }
    source_cursor_ = node_end;
    return true;
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

  // Common preflight for control-flow inline / broken-synth: the node
  // must start its own line (no source_cursor_ overrun), have no
  // comments anywhere in its range, and have a flat-emittable
  // condition. Returns false if any check fails. Sets `*line_start_out`
  // to the start of the source line containing `node_start`.
  bool can_canonicalize_control_flow(int node_start,
                                     int node_end,
                                     Expression* condition,
                                     int* line_start_out) const {
    if (has_line_locking_comment(node_start, node_end)) return false;
    if (has_interior_multiline_block_comment(node_start, node_end)) return false;
    int line_start = find_line_start(node_start);
    if (line_start < source_cursor_) return false;
    if (!is_leading_whitespace(line_start, node_start)) return false;
    if (condition != null && !can_emit_flat(condition)) return false;
    *line_start_out = line_start;
    return true;
  }

  // Renders `<header><body>` as one line. Caller provides the header
  // (`if cond: ` / `while cond: ` / `for ...: `) and the single body
  // statement. Returns false when the body isn't flat-emittable or the
  // resulting line exceeds MAX_LINE_WIDTH.
  bool try_emit_control_flow_inline(int node_start, int node_end,
                                    int line_start,
                                    const std::string& header,
                                    Expression* body_stmt,
                                    int indent) {
    if (!can_emit_flat(body_stmt)) return false;
    std::string buf = header;
    emit_expr_flat(body_stmt, PRECEDENCE_NONE, &buf);
    if (indent + static_cast<int>(buf.size()) > INLINE_CONTROL_FLOW_WIDTH) {
      return false;
    }
    int original_indent = node_start - line_start;
    int delta = indent - original_indent;
    emit_with_indent_shift(source_cursor_, line_start, delta);
    emit_spaces(indent);
    source_cursor_ = node_end;
    output_.append(buf);
    return true;
  }

  // Synthesises `<header>\n  <body>...` when source had it inline but
  // the inline form doesn't fit. Body stmts must all be flat-emittable —
  // we render each via emit_expr_flat at body_indent. Returns false if
  // any body stmt isn't flat-emittable; caller falls back to leaf.
  bool try_emit_control_flow_broken_synth(int node_start, int node_end,
                                          int line_start,
                                          const std::string& header,
                                          List<Expression*> body,
                                          int indent) {
    for (auto expr : body) {
      if (!can_emit_flat(expr)) return false;
    }
    int original_indent = node_start - line_start;
    int delta = indent - original_indent;
    emit_with_indent_shift(source_cursor_, line_start, delta);
    output_.append(indent, ' ');
    output_.append(header);
    int body_indent = indent + INDENT_STEP;
    for (auto expr : body) {
      output_.push_back('\n');
      output_.append(body_indent, ' ');
      std::string body_buf;
      emit_expr_flat(expr, PRECEDENCE_NONE, &body_buf);
      output_.append(body_buf);
    }
    source_cursor_ = node_end;
    return true;
  }

  struct IfBranch {
    Expression* cond;          // null for the final else branch
    List<Expression*> body;
  };

  // Walks an if/else-if/else chain. The parser represents `else if X` as
  // If.no = inner If (not a Sequence), and a final `else` as If.no =
  // Sequence. Returns true if every branch has a non-empty body; out is
  // populated left-to-right.
  bool collect_if_chain(If* head, std::vector<IfBranch>* out) const {
    auto first_body = as_suite_body(head->yes());
    if (first_body.is_empty()) return false;
    out->push_back({head->expression(), first_body});

    Expression* tail = head->no();
    while (tail != null) {
      if (tail->is_If()) {
        If* n = tail->as_If();
        auto y = as_suite_body(n->yes());
        if (y.is_empty()) return false;
        out->push_back({n->expression(), y});
        tail = n->no();
      } else {
        auto y = as_suite_body(tail);
        if (y.is_empty()) return false;
        out->push_back({nullptr, y});
        tail = nullptr;
      }
    }
    return true;
  }

  // Top-level dispatch for an If, including else-if chains and a final
  // else. Tries inline first (all branches single-stmt + flat-emittable
  // and fits INLINE_CONTROL_FLOW_WIDTH), then a broken-synth from AST
  // (all branch body stmts must be flat-emittable). Returns false to
  // fall through to emit_if when nothing here applies.
  bool try_emit_if_canonical(If* if_node, int indent) {
    std::vector<IfBranch> chain;
    if (!collect_if_chain(if_node, &chain)) return false;

    int node_start = pos(if_node->full_range().from());
    int node_end = pos(if_node->full_range().to());
    int line_start = 0;
    if (!can_canonicalize_control_flow(node_start, node_end,
                                       /*condition=*/nullptr, &line_start)) {
      return false;
    }
    // Every cond and every body stmt must render flat.
    for (auto& b : chain) {
      if (b.cond != nullptr && !can_emit_flat(b.cond)) return false;
      for (auto stmt : b.body) {
        if (!can_emit_flat(stmt)) return false;
      }
    }

    // Inline render — only for `if cond: body` (no else / else-if).
    // Inline forms with else aren't a shape the formatter produces;
    // `if A: a else: b` packs three semantic chunks on one line and is
    // strictly less readable than the broken form, however short.
    bool inline_eligible = chain.size() == 1 && chain[0].body.length() == 1;
    if (inline_eligible) {
      std::string buf;
      for (size_t i = 0; i < chain.size(); i++) {
        if (i == 0) {
          buf.append("if ");
          emit_expr_flat(chain[i].cond, PRECEDENCE_NONE, &buf);
          buf.append(": ");
        } else if (chain[i].cond != nullptr) {
          buf.append(" else if ");
          emit_expr_flat(chain[i].cond, PRECEDENCE_NONE, &buf);
          buf.append(": ");
        } else {
          buf.append(" else: ");
        }
        emit_expr_flat(chain[i].body.first(), PRECEDENCE_NONE, &buf);
      }
      if (indent + static_cast<int>(buf.size()) <= INLINE_CONTROL_FLOW_WIDTH) {
        int original_indent = node_start - line_start;
        int delta = indent - original_indent;
        emit_with_indent_shift(source_cursor_, line_start, delta);
        emit_spaces(indent);
        source_cursor_ = node_end;
        output_.append(buf);
        return true;
      }
    }

    // Broken-synth — emit each branch on its own lines from AST. This
    // overrides emit_if even when source was already broken, so that a
    // broken if/else chain produces deterministic output regardless of
    // exactly how the source was laid out.
    int original_indent = node_start - line_start;
    int delta = indent - original_indent;
    emit_with_indent_shift(source_cursor_, line_start, delta);

    int body_indent = indent + INDENT_STEP;
    for (size_t i = 0; i < chain.size(); i++) {
      if (i == 0) {
        output_.append(indent, ' ');
        output_.append("if ");
        std::string cb;
        emit_expr_flat(chain[i].cond, PRECEDENCE_NONE, &cb);
        output_.append(cb);
        output_.push_back(':');
      } else {
        output_.push_back('\n');
        output_.append(indent, ' ');
        if (chain[i].cond != nullptr) {
          output_.append("else if ");
          std::string cb;
          emit_expr_flat(chain[i].cond, PRECEDENCE_NONE, &cb);
          output_.append(cb);
          output_.push_back(':');
        } else {
          output_.append("else:");
        }
      }
      for (auto stmt : chain[i].body) {
        output_.push_back('\n');
        output_.append(body_indent, ' ');
        std::string sb;
        emit_expr_flat(stmt, PRECEDENCE_NONE, &sb);
        output_.append(sb);
      }
    }
    source_cursor_ = node_end;
    return true;
  }

  // Same as try_emit_if_canonical but for While.
  bool try_emit_while_canonical(While* w, int indent) {
    auto body = as_suite_body(w->body());
    if (body.is_empty()) return false;

    int node_start = pos(w->full_range().from());
    int node_end = pos(w->full_range().to());
    int line_start = 0;
    if (!can_canonicalize_control_flow(node_start, node_end,
                                       w->condition(), &line_start)) {
      return false;
    }

    std::string header;
    header.append("while ");
    emit_expr_flat(w->condition(), PRECEDENCE_NONE, &header);
    header.append(": ");

    if (body.length() == 1) {
      int saved_cursor = source_cursor_;
      size_t saved_output = output_.size();
      if (try_emit_control_flow_inline(node_start, node_end, line_start,
                                       header, body.first(), indent)) {
        return true;
      }
      source_cursor_ = saved_cursor;
      output_.resize(saved_output);
    }

    int body_first_line_start = find_line_start(pos(body.first()->full_range().from()));
    if (body_first_line_start <= node_start) {
      std::string broken_header;
      broken_header.append("while ");
      emit_expr_flat(w->condition(), PRECEDENCE_NONE, &broken_header);
      broken_header.append(":");
      if (try_emit_control_flow_broken_synth(node_start, node_end, line_start,
                                             broken_header, body, indent)) {
        return true;
      }
    }
    return false;
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
    if (node->is_Parameter()) {
      Parameter* p = node->as_Parameter();
      if (p->type() != null && !has_reliable_full_range(p->type())) return false;
      if (p->default_value() != null
          && !has_reliable_full_range(p->default_value())) {
        return false;
      }
      return true;
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
    if (node->is_Nullable()) {
      return has_reliable_full_range(node->as_Nullable()->type());
    }
    if (node->is_LiteralList() || node->is_LiteralSet()
        || node->is_LiteralMap() || node->is_LiteralByteArray()) {
      return true;
    }

    // Binary and Call are intentionally omitted. Their source bytes are
    // complete, but treating them as "safe to flatten" trips Toit's
    // greedy-Call parsing: e.g. a broken `writer.write-byte\n  to-lower
    // -case-hex X & mask` is Call(write-byte, [Binary(&, Call(hex, [X]),
    // mask)]), but `writer.write-byte to-lower-case-hex X & mask` re-
    // parses as something structurally different. Downstream code can
    // still copy the source bytes of a Binary/Call operand — it just
    // shouldn't go through this predicate when a re-parse would shift
    // the AST.

    return false;
  }

  void emit_call(Call* call, int indent) {
    int from = pos(call->full_range().from());
    int to = pos(call->full_range().to());
    Shape source_shape = shape_from_source_range(text_, from, to);
    shapes_[call] = source_shape;

    // Flat-if-fits. For a single-line source this always wins when guards
    // pass. For a multi-line source it wins only when the flat form's
    // measured width stays within MAX_LINE_WIDTH — otherwise we fall through
    // to the broken paths below.
    if (try_emit_call_flat_canonical(call, indent)) return;

    if (source_shape.is_single_line()) {
      // Source is one line but flat-if-fits rejected it — typically
      // because the rendered width exceeds MAX_LINE_WIDTH. Synthesize a
      // broken form: target on the first line, each arg at indent + 4.
      int call_start = pos(call->full_range().from());
      int call_end = pos(call->full_range().to());
      if (emit_call_forced_broken(call, call_start, call_end, indent)) return;
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
        // Determinism: source-broken `list.do:\n  it.print` collapses to
        // inline `list.do: it.print` when the rendered total fits
        // INLINE_CONTROL_FLOW_WIDTH. Otherwise the existing trailing-suite
        // path emits the broken form.
        int bare_start = pos(call->full_range().from());
        int bare_end = pos(call->full_range().to());
        if (try_emit_call_trailing_block_inline(call, bare_start, bare_end, indent)) return;
        if (emit_call_with_trailing_suite(call, body->expressions(), indent)) {
          return;
        }
      }
    }
    // No trailing block: try to canonicalize the continuation indent of
    // args that sit on their own line. Preserves the source's decision
    // about which args share the target's line vs go on continuation
    // lines; only fixes the indent of the continuation lines themselves.
    int call_start = pos(call->full_range().from());
    int call_end = pos(call->full_range().to());
    if (try_canonicalize_broken_call_in_range(call, call_start, call_end, indent)) return;
    emit_leaf(call, indent);
  }

  // Synthesises a broken form for a single-line Call whose rendered width
  // exceeds `MAX_LINE_WIDTH`. The outer prefix (e.g. `return `, `x := `)
  // and the Call's target stay on the first line at `indent`; every
  // argument moves to its own line at `indent + CALL_CONTINUATION_STEP`.
  //
  // Only fires when the source is one line AND that line is over budget.
  // Returns false otherwise or when the usual safety guards (comments,
  // unreliable ranges, Block / Lambda args) reject canonicalisation.
  bool emit_call_forced_broken(Call* call,
                               int outer_start,
                               int outer_end,
                               int indent) {
    Shape outer_shape = shape_from_source_range(text_, outer_start, outer_end);
    if (!outer_shape.is_single_line()) return false;
    int budget = call_width_budget(call);
    if (indent + outer_shape.first_line_width <= budget) return false;

    if (has_line_locking_comment(outer_start, outer_end)) return false;
    if (!has_reliable_full_range(call->target())) return false;
    if (call->arguments().is_empty()) return false;
    for (auto arg : call->arguments()) {
      // Byte-copy is safe for any arg whose range covers its bytes.
      // Block / Lambda args contain multi-line bodies that can't be
      // single-lined onto a continuation. Interpolated strings have
      // flaky range coverage, so skip those conservatively.
      if (arg->is_Block() || arg->is_Lambda()) return false;
      if (arg->is_LiteralStringInterpolation()) return false;
    }

    int outer_line_start = find_line_start(outer_start);
    if (outer_line_start < source_cursor_) return false;
    if (!is_leading_whitespace(outer_line_start, outer_start)) return false;

    // First line: outer prefix + call target. `emit_range_reindent`
    // re-indents that span to `indent` and leaves `source_cursor_` at
    // the target's end.
    int target_end = pos(call->target()->full_range().to());
    emit_range_reindent(outer_start, target_end, indent);

    int continuation_indent = indent + CALL_CONTINUATION_STEP;
    for (auto arg : call->arguments()) {
      output_.push_back('\n');
      output_.append(continuation_indent, ' ');
      emit_arg_bytes_or_recurse(arg, continuation_indent, MAX_LINE_WIDTH);
      source_cursor_ = pos(arg->full_range().to());
    }
    advance_to(outer_end);
    return true;
  }

  // Emits a Call argument at the current output position (which the
  // caller has just filled to `line_col`). Normally copies source bytes,
  // but if the arg is a too-wide `Parenthesis(Call)`, drops the parens
  // and emits the inner Call broken at this column — each continuation
  // line of the outer Call IS one arg, so `foo (bar a b)` parenthesised
  // around a single arg becomes redundant once we're already breaking:
  //
  //     foo
  //         bar
  //             a
  //             b
  //
  // not the `foo\n    (bar\n        a\n        b)` form. Parens are only
  // needed in Binary-operand contexts (`foo 1 + (bar a b)`) where greedy
  // Call would absorb differently.
  void emit_arg_bytes_or_recurse(Expression* arg, int line_col,
                                 int budget) {
    int arg_start = pos(arg->full_range().from());
    int arg_end = pos(arg->full_range().to());
    Shape s = shape_from_source_range(text_, arg_start, arg_end);
    // Fits flat at this column — just copy.
    if (s.is_single_line() && line_col + s.first_line_width <= budget) {
      output_.append(reinterpret_cast<const char*>(text_) + arg_start,
                     arg_end - arg_start);
      return;
    }
    // Parenthesis-wrapped Call that doesn't fit flat — emit the inner
    // Call broken at this column, WITHOUT the parens. Each continuation
    // line of the surrounding Call is one arg, so the parens become
    // redundant structure.
    Expression* inner = arg;
    while (inner != null && inner->is_Parenthesis()) {
      inner = inner->as_Parenthesis()->expression();
    }
    if (arg->is_Parenthesis() && inner != null && inner->is_Call()
        && can_byte_copy_call(inner->as_Call())) {
      emit_call_broken_inline(inner->as_Call(), line_col, budget);
      return;
    }
    // Fallback: verbatim byte copy, even if it overruns the budget.
    output_.append(reinterpret_cast<const char*>(text_) + arg_start,
                   arg_end - arg_start);
  }

  // Inner-Call force-break. Target sits on the current output line (we
  // assume the caller has just opened a `(` or is continuing an outer
  // Call's broken form), args break to a continuation line at
  // `target_col + CALL_CONTINUATION_STEP`. No newline before the target.
  void emit_call_broken_inline(Call* call, int target_col, int budget) {
    int t_start = pos(call->target()->full_range().from());
    int t_end = pos(call->target()->full_range().to());
    output_.append(reinterpret_cast<const char*>(text_) + t_start,
                   t_end - t_start);
    int inner_continuation = target_col + CALL_CONTINUATION_STEP;
    for (auto a : call->arguments()) {
      output_.push_back('\n');
      output_.append(inner_continuation, ' ');
      emit_arg_bytes_or_recurse(a, inner_continuation, budget);
    }
  }

  // Guard: inner Call is safe to byte-copy (same checks emit_call_forced_
  // broken applies at the top level).
  bool can_byte_copy_call(Call* call) const {
    if (!has_reliable_full_range(call->target())) return false;
    if (call->arguments().is_empty()) return false;
    for (auto a : call->arguments()) {
      if (a->is_Block() || a->is_Lambda()) return false;
      if (a->is_LiteralStringInterpolation()) return false;
    }
    return true;
  }

  // Synthesises an operator-leading broken form for a too-wide Binary
  // chain:
  //
  //   x := foo            (instead of `x := foo + bar + baz + qux`)
  //       + bar
  //       + baz
  //       + qux
  //
  // The wrapper prefix (`x := ` / `return ` / `x = ` / nothing) plus the
  // chain's first operand share the first line at `indent`. Each
  // subsequent operand sits on its own continuation line at
  // `indent + CALL_CONTINUATION_STEP`, preceded by the chain's operator.
  // Only fires when the source is a single line whose rendered width
  // exceeds MAX_LINE_WIDTH — already-broken source is preserved by the
  // verbatim emit_leaf path.
  bool try_emit_binary_forced_broken(Expression* stmt, int indent) {
    Binary* root = find_force_break_binary(stmt);
    if (root == null) return false;

    int outer_start = pos(stmt->full_range().from());
    int outer_end = pos(stmt->full_range().to());
    Shape outer_shape = shape_from_source_range(text_, outer_start, outer_end);
    if (!outer_shape.is_single_line()) return false;
    if (indent + outer_shape.first_line_width <= MAX_LINE_WIDTH) return false;

    if (has_line_locking_comment(outer_start, outer_end)) return false;

    int outer_line_start = find_line_start(outer_start);
    if (outer_line_start < source_cursor_) return false;
    if (!is_leading_whitespace(outer_line_start, outer_start)) return false;

    Token::Kind op = root->kind();
    std::vector<Expression*> operands;
    flatten_binary_chain(root, op, &operands);
    if (operands.size() < 2) return false;

    // Safety: operand bytes are copied verbatim. Reject the kinds whose
    // full_range doesn't actually cover the source span (Block / Lambda
    // bodies, and the flaky LiteralStringInterpolation). Other AST kinds
    // — including Call and Binary sub-expressions — are safe because
    // the break boundaries are explicit (newline + operator + operand).
    for (auto operand : operands) {
      if (operand == null) return false;
      if (operand->is_Block() || operand->is_Lambda()) return false;
      if (operand->is_LiteralStringInterpolation()) return false;
    }

    // First line: wrapper bytes + first operand, re-indented to `indent`.
    int first_operand_end = pos(operands[0]->full_range().to());
    emit_range_reindent(outer_start, first_operand_end, indent);

    int continuation_indent = indent + CALL_CONTINUATION_STEP;
    for (size_t i = 1; i < operands.size(); i++) {
      int op_start = pos(operands[i]->full_range().from());
      int op_end = pos(operands[i]->full_range().to());
      output_.push_back('\n');
      output_.append(continuation_indent, ' ');
      output_.append(Token::symbol(op).c_str());
      output_.push_back(' ');
      output_.append(reinterpret_cast<const char*>(text_) + op_start,
                     op_end - op_start);
    }

    source_cursor_ = outer_end;
    return true;
  }

  // Synthesises a broken form for a statement whose value is a many-
  // element collection literal:
  //
  //   x := [             (not `x := [a, b, c, d, e]`)
  //     a,
  //     b,
  //     ...
  //   ]
  //
  // The wrapper bytes (`x := ` / `return ` / nothing for a bare stmt) and
  // the opening bracket stay on the first line; each element gets its
  // own line at indent + INDENT_STEP; the closing bracket lines up with
  // the stmt's indent. Element contents are rendered flat via
  // emit_expr_flat — nested too-wide content isn't further broken here,
  // but the outer per-line structure makes that the rare case.
  bool try_emit_stmt_force_broken_collection(Expression* stmt, int indent) {
    Expression* coll = find_force_break_collection(stmt);
    if (coll == null) return false;

    int outer_start = pos(stmt->full_range().from());
    int outer_end = pos(stmt->full_range().to());
    // Only synthesise a per-line broken form when the stmt is currently
    // a single line wider than MAX_LINE_WIDTH. Short collections stay
    // flat; already-broken source is preserved by the verbatim leaf
    // fallback (emit_stmt_flat rejected for width, we'd spuriously
    // break otherwise).
    Shape outer_shape = shape_from_source_range(text_, outer_start, outer_end);
    if (!outer_shape.is_single_line()) return false;
    if (indent + outer_shape.first_line_width <= MAX_LINE_WIDTH) return false;

    if (has_line_locking_comment(outer_start, outer_end)) return false;

    int outer_line_start = find_line_start(outer_start);
    if (outer_line_start < source_cursor_) return false;
    if (!is_leading_whitespace(outer_line_start, outer_start)) return false;

    int coll_start = pos(coll->full_range().from());
    int open_len = coll->is_LiteralByteArray() ? 2 : 1;  // `#[` vs `[`/`{`
    int after_open = coll_start + open_len;

    // Emit wrapper prefix + opening bracket, re-indented to `indent`.
    emit_range_reindent(outer_start, after_open, indent);

    // Render each element on its own line with trailing comma. Keys and
    // values live on the same line for Maps — the break is one entry per
    // line, not key and value on separate lines.
    int element_indent = indent + INDENT_STEP;
    auto emit_element = [&](Expression* e) {
      output_.push_back('\n');
      output_.append(element_indent, ' ');
      std::string buf;
      emit_expr_flat(e, PRECEDENCE_NONE, &buf);
      output_.append(buf);
      output_.push_back(',');
    };
    if (coll->is_LiteralList()) {
      for (auto e : coll->as_LiteralList()->elements()) emit_element(e);
    } else if (coll->is_LiteralByteArray()) {
      for (auto e : coll->as_LiteralByteArray()->elements()) emit_element(e);
    } else if (coll->is_LiteralSet()) {
      for (auto e : coll->as_LiteralSet()->elements()) emit_element(e);
    } else if (coll->is_LiteralMap()) {
      auto m = coll->as_LiteralMap();
      for (int i = 0; i < m->keys().length(); i++) {
        output_.push_back('\n');
        output_.append(element_indent, ' ');
        std::string kb;
        emit_expr_flat(m->keys()[i], PRECEDENCE_NONE, &kb);
        std::string vb;
        emit_expr_flat(m->values()[i], PRECEDENCE_NONE, &vb);
        output_.append(kb);
        output_.append(": ");
        output_.append(vb);
        output_.push_back(',');
      }
    }

    // Closing bracket.
    output_.push_back('\n');
    output_.append(indent, ' ');
    char close_char = coll->is_LiteralMap() || coll->is_LiteralSet()
                    ? '}' : ']';
    output_.push_back(close_char);

    source_cursor_ = outer_end;
    return true;
  }

  // Emits a multi-line Call in canonical broken form: target (and any
  // outer wrapper bytes — `return ` / `x := ` / nothing) on the first
  // line at `indent`, then every argument on its own continuation line
  // at `indent + CALL_CONTINUATION_STEP`. Source distribution of args
  // across lines is ignored — the output depends only on (AST + width).
  //
  // Falls back to source-distribution-preserving emission when any arg
  // is itself multi-line in source. emit_arg_bytes_or_recurse can only
  // byte-copy; multi-line args need indent-shifting on their
  // continuation lines, which the per-arg path doesn't apply.
  //
  // The Call may be the whole statement (outer_start/end = call's
  // range) or wrapped in Return / DeclarationLocal / assignment
  // Binary (outer_start/end = the wrapper's range).
  //
  // Returns false if guards fail (line-locking comments, unreliable
  // full_range, the call isn't actually broken in source, etc.);
  // caller falls back to leaf.
  bool try_canonicalize_broken_call_in_range(Call* call,
                                             int outer_start,
                                             int outer_end,
                                             int indent) {
    if (has_line_locking_comment(outer_start, outer_end)) return false;
    if (!has_reliable_full_range(call->target())) return false;
    if (call->arguments().is_empty()) return false;
    for (auto arg : call->arguments()) {
      if (arg->is_Block() || arg->is_Lambda()) return false;
      if (!has_reliable_full_range(arg)) return false;
    }

    int outer_line_start = find_line_start(outer_start);
    if (outer_line_start < source_cursor_) return false;
    if (!is_leading_whitespace(outer_line_start, outer_start)) return false;

    // Skip when the source is single-line — that's `try_emit_call_flat_
    // canonical`'s territory (or `emit_call_forced_broken` if the flat
    // form was too wide). This function only runs for already-broken
    // source.
    Shape outer_shape = shape_from_source_range(text_, outer_start, outer_end);
    if (outer_shape.is_single_line()) return false;

    // Per-arg canonical emission requires every arg to be single-line
    // in source — emit_arg_bytes_or_recurse byte-copies, and a
    // multi-line arg's continuation lines wouldn't be re-indented to
    // the new column. Fall back to the source-distribution-preserving
    // path when any arg is multi-line.
    bool all_args_single_line = true;
    for (auto arg : call->arguments()) {
      Shape s = shape_from_source_range(text_,
                                        pos(arg->full_range().from()),
                                        pos(arg->full_range().to()));
      if (!s.is_single_line()) { all_args_single_line = false; break; }
    }

    // Per-arg canonical also requires wrapper + target to fit on one
    // line in source (i.e. the wrapper didn't already break before
    // its Call target). If the source has `x :=\n  Call`, putting
    // args at `outer_indent + CALL_CONTINUATION_STEP` would land them
    // at the same column as the target, and the parser would treat
    // each as a sibling stmt instead of a continuation argument.
    // Resolving that needs rendering the wrapper + target on one
    // line, which the per-arg path doesn't do today; fall back to the
    // source-distribution path.
    int target_start = pos(call->target()->full_range().from());
    bool wrapper_target_one_line =
        find_line_start(target_start) == outer_line_start;

    if (all_args_single_line && wrapper_target_one_line) {
      // First line: outer prefix bytes + call target, re-indented to
      // `indent`. Cursor lands at target's end.
      int target_end = pos(call->target()->full_range().to());
      emit_range_reindent(outer_start, target_end, indent);

      int continuation_indent = indent + CALL_CONTINUATION_STEP;
      for (auto arg : call->arguments()) {
        output_.push_back('\n');
        output_.append(continuation_indent, ' ');
        emit_arg_bytes_or_recurse(arg, continuation_indent, MAX_LINE_WIDTH);
        source_cursor_ = pos(arg->full_range().to());
      }
      advance_to(outer_end);
      return true;
    }

    // Source-distribution-preserving fallback: re-indents the args'
    // continuation lines but leaves the source's choice of which args
    // sit on the target's line vs. continuation lines intact. Used
    // when some arg is multi-line in source (e.g. a multi-line list
    // literal) — that arg needs indent-shifting via
    // `emit_range_reindent`, which requires the arg to start on its
    // own line, so we can't unilaterally promote it to a continuation.
    int first_break = -1;
    for (int i = 0; i < call->arguments().length(); i++) {
      int arg_line = find_line_start(
          pos(call->arguments()[i]->full_range().from()));
      if (arg_line > outer_line_start) {
        first_break = i;
        break;
      }
    }
    if (first_break < 0) return false;

    int break_line_start = find_line_start(
        pos(call->arguments()[first_break]->full_range().from()));
    emit_range_reindent(outer_start, break_line_start, indent);

    int continuation_indent = indent + CALL_CONTINUATION_STEP;
    for (int i = first_break; i < call->arguments().length(); i++) {
      auto arg = call->arguments()[i];
      emit_range_reindent(pos(arg->full_range().from()),
                          pos(arg->full_range().to()),
                          continuation_indent);
    }
    advance_to(outer_end);
    return true;
  }

  // For `list.do: it.print` style: a Call whose last argument is a
  // Block / Lambda with a single-stmt, parameter-less body. Renders
  // inline `<call header>: <body_stmt>` (or `:: ` for Lambda) when
  // the result fits INLINE_CONTROL_FLOW_WIDTH. Returns false to let
  // emit_call_with_trailing_suite handle the broken form otherwise.
  //
  // The "call header" is the source bytes from the Call's start up
  // to (but not including) the Block/Lambda's `:` token, which is
  // the Block's full_range start. That includes the target plus any
  // non-block args.
  bool try_emit_call_trailing_block_inline(Call* call,
                                           int outer_start,
                                           int outer_end,
                                           int indent) {
    if (call->arguments().is_empty()) return false;
    Expression* last = call->arguments().last();
    Sequence* body = nullptr;
    List<Parameter*> params;
    bool is_lambda = false;
    if (last->is_Block()) {
      body = last->as_Block()->body();
      params = last->as_Block()->parameters();
    } else if (last->is_Lambda()) {
      body = last->as_Lambda()->body();
      params = last->as_Lambda()->parameters();
      is_lambda = true;
    } else {
      return false;
    }
    if (body == nullptr) return false;
    auto exprs = body->expressions();
    if (exprs.length() != 1) return false;
    Expression* body_stmt = exprs.first();
    if (!can_emit_flat(body_stmt)) return false;
    for (auto p : params) {
      if (!has_reliable_full_range(p)) return false;
    }

    if (has_line_locking_comment(outer_start, outer_end)) return false;
    if (has_interior_multiline_block_comment(outer_start, outer_end)) return false;

    int line_start = find_line_start(outer_start);
    if (line_start < source_cursor_) return false;
    if (!is_leading_whitespace(line_start, outer_start)) return false;

    // Header bytes from outer_start to the `:` token (= block's
    // full_range start). Must be single-line — otherwise the wrapper
    // or call header has its own break and inline doesn't apply.
    // For a bare Call, outer_start == call_start. For a wrapped Call
    // (Return / DeclLocal / assignment Binary), outer_start is the
    // wrapper's start and the byte range includes the wrapper tokens.
    int block_start = pos(last->full_range().from());
    if (block_start <= outer_start) return false;
    for (int i = outer_start; i < block_start; i++) {
      if (text_[i] == '\n') return false;
    }
    int header_len = block_start - outer_start;

    // Also: every other arg (non-block) must be reliable for byte-copy.
    // The byte range outer_start..block_start covers them all, and
    // we're copying it verbatim, so we need them to be source-faithful.
    for (auto arg : call->arguments()) {
      if (arg == last) continue;
      if (!has_reliable_full_range(arg)) return false;
    }
    if (!has_reliable_full_range(call->target())) return false;

    // Render block params as `| p1 p2 ... | `. Each param is byte-
    // copied from its full_range — this preserves type annotations
    // and any other syntactic decoration.
    std::string params_buf;
    if (!params.is_empty()) {
      params_buf.append("| ");
      for (int i = 0; i < params.length(); i++) {
        if (i > 0) params_buf.push_back(' ');
        int p_start = pos(params[i]->full_range().from());
        int p_end = pos(params[i]->full_range().to());
        params_buf.append(reinterpret_cast<const char*>(text_) + p_start,
                          p_end - p_start);
      }
      params_buf.append(" | ");
    }

    const char* sep = is_lambda ? ":: " : ": ";
    int sep_len = is_lambda ? 3 : 2;

    std::string body_buf;
    emit_expr_flat(body_stmt, PRECEDENCE_NONE, &body_buf);
    int total = indent + header_len + sep_len
              + static_cast<int>(params_buf.size())
              + static_cast<int>(body_buf.size());
    if (total > INLINE_CONTROL_FLOW_WIDTH) return false;

    int original_indent = outer_start - line_start;
    int delta = indent - original_indent;
    emit_with_indent_shift(source_cursor_, line_start, delta);
    emit_spaces(indent);
    output_.append(reinterpret_cast<const char*>(text_) + outer_start, header_len);
    output_.append(sep);
    output_.append(params_buf);
    output_.append(body_buf);
    source_cursor_ = outer_end;
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

    // Target must be single-line in source — a multi-line target (e.g. a
    // Dot chain already broken across lines) can't be flattened here.
    int target_start = pos(target->full_range().from());
    int target_end = pos(target->full_range().to());
    if (!shape_from_source_range(text_, target_start, target_end).is_single_line()) {
      return false;
    }


    int flat_width = indent + (target_end - target_start);
    int prev_end = target_end;
    for (auto arg : call->arguments()) {
      int arg_start = pos(arg->full_range().from());
      int arg_end = pos(arg->full_range().to());
      // Gap between tokens may contain only spaces, tabs, or newlines.
      // Newlines mean the source was broken across lines; we'll collapse
      // them. Anything else (comments, other chars) blocks flat emission.
      for (int i = prev_end; i < arg_start; i++) {
        uint8 c = text_[i];
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r') return false;
      }
      // Each arg must itself be single-line in source — otherwise its
      // internal layout would be destroyed by the flat copy.
      if (!shape_from_source_range(text_, arg_start, arg_end).is_single_line()) {
        return false;
      }
      flat_width += (arg->is_Block() ? 0 : 1) + (arg_end - arg_start);
      prev_end = arg_end;
    }
    if (flat_width > call_width_budget(call)) return false;

    int original_indent = call_start - line_start;
    int delta = indent - original_indent;
    // Shift preceding trivia (blank lines, standalone comments) by the
    // same delta we're about to apply to this call's first line.
    emit_with_indent_shift(source_cursor_, line_start, delta);
    output_.append(indent, ' ');

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
    // Caps consecutive blank-line runs to MAX_BLANK_LINES. After each
    // `\n` we look ahead at the next line:
    //   - at end of [from, to) → just emit `\n`; caller appends the
    //     canonical indent for the next stmt.
    //   - next non-ws byte is `\n` → blank line; emit `\n + ws` if
    //     under the cap, else skip the whole line.
    //   - next non-ws byte is content (e.g. a comment) → continuation
    //     line; emit `\n + (ws + delta)` and reset the blank-run
    //     counter.
    static const int MAX_BLANK_LINES = 1;
    int i = from;
    int blank_run = 0;
    while (i < to) {
      uint8 c = text_[i];
      i++;
      if (c != '\n') {
        output_.push_back(c);
        if (c != ' ' && c != '\t' && c != '\r') blank_run = 0;
        continue;
      }
      // Just consumed a `\n` at position i-1.
      int ws = 0;
      while (i + ws < to && text_[i + ws] == ' ') ws++;
      bool at_end = (i + ws >= to);
      bool next_is_blank = !at_end && (text_[i + ws] == '\n');

      if (at_end) {
        output_.push_back('\n');
        // Absorb trailing ws (caller appends canonical indent).
        i += ws;
        blank_run = 0;
      } else if (next_is_blank) {
        blank_run++;
        if (blank_run <= MAX_BLANK_LINES) {
          output_.push_back('\n');
          output_.append(reinterpret_cast<const char*>(text_) + i, ws);
        }
        // else: skip the entire blank line (no `\n`, no ws).
        i += ws;
      } else {
        // Continuation / comment line.
        output_.push_back('\n');
        int new_ws = std::max(0, ws + delta);
        output_.append(new_ws, ' ');
        i += ws;
        blank_run = 0;
      }
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
