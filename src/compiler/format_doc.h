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
#include <vector>

#include "../top.h"

namespace toit {
namespace compiler {

// All layout opinions of the formatter, in one place. Values are
// calibrated against the reference corpus (artemis/src); see PLAN.md
// for the measurements.
struct FormatStyle {
  // Indentation of suites: control-flow bodies, method bodies,
  // block/lambda bodies, broken collection elements.
  int indent_step = 2;
  // Indentation of continuation lines: broken call arguments, wrapped
  // method parameters, broken class-header clauses, broken binary
  // chains.
  int continuation_step = 4;
  // Node-relative width budget: a group breaks when its single-line
  // rendering is wider than this, measured from the group's start.
  int max_width = 100;
  // Damped absolute backstop: a group may end at most at column
  // `max_width + min(start_column, slack)`. Lets indented code drift
  // right instead of being squeezed, but caps the drift.
  int slack = 20;
  // Blank-line runs between statements / members are preserved up to
  // this many lines.
  int max_blank_lines = 2;
  // Spaces between a line's last token and a trailing comment
  // (corpus: 118 two-space vs 11 one-space).
  int trailing_comment_gap = 2;
  // A collection literal written across several lines stays broken
  // even when it would fit on one (the "magic trailing comma" rule of
  // Prettier/Black): authors curate config-like collections line by
  // line. The one deliberate exception to pure-AST determinism.
  bool keep_multiline_collections = true;
  // Constructs that pack a suite onto their header's line (`foo: body`,
  // `if c: body`, `list.do: it`) use this tighter budget: two semantic
  // chunks on one line are harder to scan than one wide expression.
  int inline_suite_width = 100;
  // An inline suite body may have at most this many tokens; heavier
  // bodies go to their own line regardless of width.
  int max_inline_suite_tokens = 1000;
  // Extra inline width for suite bodies that are a single `return` or
  // `throw`: terminal one-liners read well inline.
  int inline_return_throw_bonus = 0;
  // Whether a suite body that itself contains a suite (`if o is List:
  // return o.map: ...`) may go inline. Stacked `:` suites on one line
  // make the reader resolve which colon owns which body.
  bool inline_nested_suites = true;
  // Parenthesize binary-operator arguments of calls even where the
  // grammar doesn't require it (`foo (end - start)`).
  bool paren_binary_arguments = false;
};

// A layout document. Lowering builds a Doc tree from the AST; the
// printer renders it. The printer makes every flat-vs-broken decision;
// lowering only describes the alternatives.
//
// Nodes are allocated through DocBuilder and live as long as it does.
class Doc {
 public:
  enum Kind {
    // Atomic single-line text. Must not contain newlines.
    TEXT,
    // Pre-rendered multi-line text. The first line starts at the
    // current position. Interior lines are emitted as-is when
    // `original_column` is -1 (multi-line strings, whose bytes are
    // content), or shifted by `current indent - original_column` when
    // it is set (frozen statements, line-spanning comments — their
    // interior alignment follows the construct).
    VERBATIM,
    CONCAT,
    // The unit of flat-vs-broken choice. Renders flat iff the child's
    // single-line width fits the budget (see FormatStyle).
    GROUP,
    // Adds `delta` to the indentation of lines opened inside.
    INDENT,
    // Newline when broken; `separator` (usually one space) when flat.
    LINE,
    // Newline when broken; nothing when flat.
    SOFTLINE,
    // Always a newline. Forces every enclosing group to break.
    HARDLINE,
    // Emits nothing, but forces every enclosing group to break. Used
    // for trailing `//` comments: nothing may follow them on the
    // line, so the list they sit in must render broken.
    BREAK_PARENT,
    // Renders `broken` when the nearest enclosing group is broken,
    // `flat` when it is flat. Used where Toit's grammar needs
    // different tokens per mode (e.g. parens around call arguments,
    // trailing commas).
    IF_BROKEN,
  };

  Kind kind() const { return kind_; }

  const std::string& text() const { return text_; }
  const std::vector<Doc*>& children() const { return children_; }
  Doc* child() const { return children_[0]; }
  Doc* broken_alternative() const { return children_[0]; }
  Doc* flat_alternative() const { return children_[1]; }
  int indent_delta() const { return indent_delta_; }
  // Width budget override for GROUP; -1 means FormatStyle::max_width.
  int budget() const { return budget_; }
  // VERBATIM: source column the text originally started at, or -1
  // when interior lines must not be touched.
  int original_column() const { return original_column_; }

 private:
  explicit Doc(Kind kind) : kind_(kind) {}

  Kind kind_;
  std::string text_;           // TEXT, VERBATIM, LINE (separator).
  std::vector<Doc*> children_; // CONCAT, GROUP, INDENT, IF_BROKEN.
  int indent_delta_ = 0;       // INDENT.
  int budget_ = -1;            // GROUP.
  int original_column_ = -1;   // VERBATIM.

  // Memoized single-line width in display columns (UTF-8 aware);
  // INFINITE_WIDTH when the node cannot render on one line.
  mutable int flat_width_ = -1;

  friend class DocBuilder;
  friend class DocPrinter;
};

// Allocates and owns Doc nodes.
class DocBuilder {
 public:
  DocBuilder() {}
  ~DocBuilder();

  DocBuilder(const DocBuilder&) = delete;
  DocBuilder& operator=(const DocBuilder&) = delete;

  Doc* text(std::string s);
  // `original_column >= 0` requests delta-shifting of interior lines
  // (see Doc::VERBATIM).
  Doc* verbatim(std::string s, int original_column = -1);
  Doc* concat(std::vector<Doc*> children);
  Doc* group(Doc* child, int budget = -1);
  Doc* indent(int delta, Doc* child);
  Doc* line();             // Newline or single space.
  Doc* softline();         // Newline or nothing.
  Doc* hardline();
  Doc* break_parent();
  Doc* blank_lines(int count);  // `count` blank lines (count+1 hardlines).
  Doc* if_broken(Doc* broken, Doc* flat);
  Doc* nil();              // Empty text.

 private:
  Doc* make(Doc::Kind kind);

  std::vector<Doc*> all_;
};

// Whether the doc contains any potential line break (LINE, SOFTLINE,
// HARDLINE, BREAK_PARENT, or multi-line VERBATIM). Used by lowering to
// decide which call arguments may be glued to the target's line.
bool doc_has_breakpoints(const Doc* doc);

// Renders `doc` starting at indentation `base_indent`. The result's
// first line is not indented (the caller has already emitted any
// leading indentation); lines opened inside are indented according to
// the INDENT structure on top of `base_indent`. Never emits trailing
// whitespace before a newline.
std::string print_doc(const Doc* doc, int base_indent, const FormatStyle& style);

} // namespace toit::compiler
} // namespace toit
