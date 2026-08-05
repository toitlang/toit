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

#include <initializer_list>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace toit {
namespace compiler {

struct FormatStyle {
  int continuation_step = 4;
};

// Formatter phase overview:
//
//   AST lowering -> Layout -> SelectedPlan -> whitespace repairs -> FinalPlan
//                                                               + syntax insertions -> rendering
//
// Layout selection measures logical tokens without synthesized punctuation.
// The selected token events stay private, so later phases cannot accidentally
// depend on or change their order. Repairs can address exposed gaps but cannot
// access token events. Freezing makes the result immutable; syntax protection
// then responds to its line topology without feeding punctuation back into
// width selection.
// Method return-type placement is the sole token-order exception and is owned
// by format_return_type.cc before repairs run.

// A zero-width position in a layout. Expression lowering records markers at
// syntax boundaries; later phases can then reason about selected newlines
// without searching rendered text.
class LayoutMarker {
 public:
  LayoutMarker() : id_(-1) {}

  bool is_valid() const { return id_ >= 0; }

 private:
  explicit LayoutMarker(int id) : id_(id) {}

  int id_;

  friend class LayoutBuilder;
  friend class LayoutSelector;
  friend class SelectedPlan;
  friend class PlanInsertions;
};

// Identifies one whitespace decision. Handles are deliberately restricted to
// whitespace: no ordinary post-selection pass gets a handle with which it
// could move or replace a token.
class LayoutGap {
 public:
  LayoutGap() : id_(-1) {}

  bool is_valid() const { return id_ >= 0; }

 private:
  explicit LayoutGap(int id) : id_(id) {}

  int id_;

  friend class LayoutBuilder;
  friend class LayoutSelector;
  friend class SelectedPlan;
  friend class WhitespaceEdits;
};

enum class GapState {
  // Emit the gap's separator. It is normally one space, but may be empty.
  FLAT,
  NEWLINE,
};

// A tree of logical tokens and possible whitespace. It contains neither
// source parentheses nor synthesized parentheses: layout selection should
// measure the program's logical text, while syntax protection runs later.
//
// LINE follows its surrounding GROUP. SPACE starts flat even when that group
// breaks, but still exposes a legal newline for an aesthetic repair. HARDLINE
// is structural and can never be flattened.
class Layout {
 public:
  enum Kind {
    TEXT,
    CONCAT,
    GROUP,
    INDENT,
    LINE,
    SPACE,
    HARDLINE,
    MARK,
  };

 private:
  explicit Layout(Kind kind) : kind_(kind) {}

  Kind kind_;
  std::string text_;
  std::vector<Layout*> children_;
  Layout* child_ = nullptr;
  int indentation_ = 0;
  LayoutMarker marker_;
  LayoutGap gap_;

  friend class LayoutBuilder;
  friend class LayoutSelector;
};

// Owns Layout nodes and supplies the small vocabulary used by lowering.
// Pointers returned by the builder remain valid for its lifetime.
class LayoutBuilder {
 public:
  Layout* text(const std::string& text);
  Layout* concat(std::vector<Layout*> children);
  Layout* concat(std::initializer_list<Layout*> children) {
    return concat(std::vector<Layout*>(children));
  }
  Layout* group(Layout* child);
  Layout* indent(int spaces, Layout* child);

  LayoutGap gap();
  Layout* line(const std::string& flat_separator = " ");
  Layout* line(LayoutGap gap, const std::string& flat_separator = " ");
  Layout* space(LayoutGap gap, const std::string& separator = " ");
  Layout* hardline();

  LayoutMarker marker();
  Layout* mark(LayoutMarker marker);

 private:
  Layout* allocate(Layout::Kind kind);

  std::vector<std::unique_ptr<Layout>> layouts_;
  int next_marker_ = 0;
  int next_gap_ = 0;
};

class WhitespaceEdits;
class FinalPlan;

// A layout after every GROUP has selected its flat or broken form. This is the
// only mutable phase: aesthetic rules may change whitespace states that the
// layout explicitly offered. Token events are private and have no relocation
// API, making preservation of token order an enforceable invariant.
class SelectedPlan {
 public:
  int line_of(LayoutMarker marker) const;
  bool has_break_between(LayoutMarker first, LayoutMarker second) const;

  bool can_select(LayoutGap gap, GapState state) const;
  bool is_selected(LayoutGap gap, GapState state) const;
  // Returns false, without changing the plan, if two rules requested
  // contradictory states. Callers can report `edits.conflicts()`.
  bool apply(const WhitespaceEdits& edits);

  FinalPlan freeze() &&;

 private:
  struct Event {
    enum Kind { TEXT, GAP, MARK };

    Kind kind;
    std::string text;
    int indentation = 0;
    bool newline = false;
    bool can_flat = false;
    bool can_newline = false;
    LayoutGap gap;
    LayoutMarker marker;
  };

  const Event& gap_event(LayoutGap gap) const;
  Event& gap_event(LayoutGap gap);
  int marker_index(LayoutMarker marker) const;

  std::vector<Event> events_;
  std::vector<int> marker_indices_;
  std::vector<int> gap_indices_;

  friend class FinalPlan;
  friend class LayoutSelector;
  friend std::string render_plan(const FinalPlan&, const class PlanInsertions&);
};

// Freezing closes the whitespace-repair phase. Later phases may inspect this
// final line topology, but cannot mutate it.
class FinalPlan {
 public:
  int line_of(LayoutMarker marker) const { return selected_.line_of(marker); }
  bool has_break_between(LayoutMarker first, LayoutMarker second) const {
    return selected_.has_break_between(first, second);
  }

 private:
  explicit FinalPlan(SelectedPlan selected) : selected_(std::move(selected)) {}

  SelectedPlan selected_;

  friend class SelectedPlan;
  friend std::string render_plan(const FinalPlan&, const class PlanInsertions&);
};

// Syntax added after line selection lives beside, rather than inside, the
// final plan. Insertions are restricted to single-line text and therefore
// cannot retroactively influence width or line selection.
class PlanInsertions {
 public:
  void insert_before(LayoutMarker marker, const std::string& text);
  void insert_after(LayoutMarker marker, const std::string& text);

 private:
  struct AtMarker {
    std::vector<std::string> before;
    std::vector<std::string> after;
  };

  const AtMarker* at(LayoutMarker marker) const;
  std::unordered_map<int, AtMarker> insertions_;

  friend std::string render_plan(const FinalPlan&, const PlanInsertions&);
};

SelectedPlan select_layout(Layout* root, int preferred_width);
std::string render_plan(const FinalPlan& plan,
                        const PlanInsertions& insertions = PlanInsertions());

} // namespace compiler
} // namespace toit
