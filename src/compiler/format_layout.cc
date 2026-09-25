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

#include "../top.h"

#include "format_layout.h"

#include <limits>
#include <utility>

namespace toit {
namespace compiler {

Layout* LayoutBuilder::allocate(Layout::Kind kind) {
  layouts_.push_back(std::unique_ptr<Layout>(new Layout(kind)));
  return layouts_.back().get();
}

Layout* LayoutBuilder::text(const std::string& text) {
  ASSERT(text.find('\n') == std::string::npos);
  Layout* result = allocate(Layout::TEXT);
  result->text_ = text;
  return result;
}

Layout* LayoutBuilder::concat(std::vector<Layout*> children) {
  Layout* result = allocate(Layout::CONCAT);
  result->children_ = std::move(children);
  return result;
}

Layout* LayoutBuilder::group(Layout* child) {
  ASSERT(child != null);
  Layout* result = allocate(Layout::GROUP);
  result->child_ = child;
  return result;
}

Layout* LayoutBuilder::indent(int spaces, Layout* child) {
  ASSERT(spaces >= 0);
  ASSERT(child != null);
  Layout* result = allocate(Layout::INDENT);
  result->indentation_ = spaces;
  result->child_ = child;
  return result;
}

LayoutGap LayoutBuilder::gap() { return LayoutGap(next_gap_++); }

Layout* LayoutBuilder::line(const std::string& flat_separator) {
  return line(gap(), flat_separator);
}

Layout* LayoutBuilder::line(LayoutGap gap, const std::string& flat_separator) {
  ASSERT(gap.is_valid());
  ASSERT(flat_separator.find('\n') == std::string::npos);
  Layout* result = allocate(Layout::LINE);
  result->text_ = flat_separator;
  result->gap_ = gap;
  return result;
}

Layout* LayoutBuilder::space(LayoutGap gap, const std::string& separator) {
  ASSERT(gap.is_valid());
  ASSERT(separator.find('\n') == std::string::npos);
  Layout* result = allocate(Layout::SPACE);
  result->text_ = separator;
  result->gap_ = gap;
  return result;
}

Layout* LayoutBuilder::hardline() { return allocate(Layout::HARDLINE); }

LayoutMarker LayoutBuilder::marker() { return LayoutMarker(next_marker_++); }

Layout* LayoutBuilder::mark(LayoutMarker marker) {
  ASSERT(marker.is_valid());
  Layout* result = allocate(Layout::MARK);
  result->marker_ = marker;
  return result;
}

class LayoutSelector {
 public:
  explicit LayoutSelector(int preferred_width)
      : preferred_width_(preferred_width < 0 ? 0 : preferred_width) {}

  SelectedPlan select(Layout* root) {
    ASSERT(root != null);
    append(root, 0, BROKEN);
    return std::move(result_);
  }

 private:
  enum Mode { FLAT, BROKEN };

  // HARDLINE makes a flat rendering impossible. Saturating widths at this
  // sentinel avoids overflow; it is not a hard source width.
  static const int INFINITE_WIDTH = std::numeric_limits<int>::max() / 4;

  int preferred_width_;
  int logical_column_ = 0;
  SelectedPlan result_;
  std::unordered_map<Layout*, int> flat_widths_;

  static int add_width(int left, int right) {
    if (left >= INFINITE_WIDTH || right >= INFINITE_WIDTH) {
      return INFINITE_WIDTH;
    }
    if (left > INFINITE_WIDTH - right) return INFINITE_WIDTH;
    return left + right;
  }

  int flat_width(Layout* layout) {
    auto existing = flat_widths_.find(layout);
    if (existing != flat_widths_.end()) return existing->second;

    int result;
    switch (layout->kind_) {
    case Layout::TEXT:
    case Layout::LINE:
    case Layout::SPACE:
      result = layout->text_.size() >= static_cast<size_t>(INFINITE_WIDTH)
                   ? INFINITE_WIDTH
                   : static_cast<int>(layout->text_.size());
      break;
    case Layout::MARK:
      result = 0;
      break;
    case Layout::CONCAT:
      result = 0;
      for (Layout* child : layout->children_) {
        result = add_width(result, flat_width(child));
      }
      break;
    case Layout::GROUP:
    case Layout::INDENT:
      result = flat_width(layout->child_);
      break;
    case Layout::HARDLINE:
      result = INFINITE_WIDTH;
      break;
    default:
      UNREACHABLE();
    }
    flat_widths_[layout] = result;
    return result;
  }

  void append_text(const std::string& text) {
    SelectedPlan::Event event;
    event.kind = SelectedPlan::Event::TEXT;
    event.text = text;
    result_.events_.push_back(std::move(event));
    int width = text.size() >= static_cast<size_t>(INFINITE_WIDTH)
                    ? INFINITE_WIDTH
                    : static_cast<int>(text.size());
    logical_column_ = add_width(logical_column_, width);
  }

  void append_gap(LayoutGap gap, const std::string& text, int indentation,
                  bool newline, bool can_flat, bool can_newline) {
    SelectedPlan::Event event;
    event.kind = SelectedPlan::Event::GAP;
    event.text = text;
    event.indentation = indentation;
    event.newline = newline;
    event.can_flat = can_flat;
    event.can_newline = can_newline;
    event.gap = gap;
    int index = result_.events_.size();
    result_.events_.push_back(std::move(event));
    if (gap.is_valid()) {
      if (gap.id_ >= static_cast<int>(result_.gap_indices_.size())) {
        result_.gap_indices_.resize(gap.id_ + 1, -1);
      }
      ASSERT(result_.gap_indices_[gap.id_] == -1);
      result_.gap_indices_[gap.id_] = index;
    }
    if (newline) {
      logical_column_ = indentation;
    } else {
      int width = text.size() >= static_cast<size_t>(INFINITE_WIDTH)
                      ? INFINITE_WIDTH
                      : static_cast<int>(text.size());
      logical_column_ = add_width(logical_column_, width);
    }
  }

  void append(Layout* layout, int indentation, Mode mode) {
    switch (layout->kind_) {
    case Layout::TEXT:
      append_text(layout->text_);
      return;
    case Layout::CONCAT:
      for (Layout* child : layout->children_)
        append(child, indentation, mode);
      return;
    case Layout::GROUP: {
      // A flat parent commits all descendant LINE nodes to their flat form.
      // Otherwise nested groups could contradict the parent's width choice.
      if (mode == FLAT) {
        append(layout->child_, indentation, FLAT);
        return;
      }
      int available = preferred_width_ - logical_column_;
      if (available < 0) available = 0;
      Mode child_mode = flat_width(layout->child_) <= available ? FLAT : BROKEN;
      append(layout->child_, indentation, child_mode);
      return;
    }
    case Layout::INDENT:
      append(layout->child_, indentation + layout->indentation_, mode);
      return;
    case Layout::LINE:
      append_gap(layout->gap_, layout->text_, indentation, mode == BROKEN, true,
                 true);
      return;
    case Layout::SPACE:
      append_gap(layout->gap_, layout->text_, indentation, false, true, true);
      return;
    case Layout::HARDLINE:
      append_gap(LayoutGap(), "", indentation, true, false, true);
      return;
    case Layout::MARK: {
      SelectedPlan::Event event;
      event.kind = SelectedPlan::Event::MARK;
      event.marker = layout->marker_;
      int index = result_.events_.size();
      result_.events_.push_back(std::move(event));
      if (layout->marker_.id_ >=
          static_cast<int>(result_.marker_indices_.size())) {
        result_.marker_indices_.resize(layout->marker_.id_ + 1, -1);
      }
      ASSERT(result_.marker_indices_[layout->marker_.id_] == -1);
      result_.marker_indices_[layout->marker_.id_] = index;
      return;
    }
    default:
      UNREACHABLE();
    }
  }
};

const int LayoutSelector::INFINITE_WIDTH;

int SelectedPlan::marker_index(LayoutMarker marker) const {
  ASSERT(marker.is_valid());
  ASSERT(marker.id_ < static_cast<int>(marker_indices_.size()));
  int index = marker_indices_[marker.id_];
  ASSERT(index >= 0);
  return index;
}

const SelectedPlan::Event& SelectedPlan::gap_event(LayoutGap gap) const {
  ASSERT(gap.is_valid());
  ASSERT(gap.id_ < static_cast<int>(gap_indices_.size()));
  int index = gap_indices_[gap.id_];
  ASSERT(index >= 0);
  return events_[index];
}

SelectedPlan::Event& SelectedPlan::gap_event(LayoutGap gap) {
  return const_cast<Event&>(
      static_cast<const SelectedPlan*>(this)->gap_event(gap));
}

int SelectedPlan::line_of(LayoutMarker marker) const {
  int stop = marker_index(marker);
  int line = 0;
  for (int i = 0; i < stop; i++) {
    if (events_[i].kind == Event::GAP && events_[i].newline) line++;
  }
  return line;
}

bool SelectedPlan::has_break_between(LayoutMarker first,
                                     LayoutMarker second) const {
  int begin = marker_index(first);
  int end = marker_index(second);
  ASSERT(begin <= end);
  for (int i = begin + 1; i < end; i++) {
    if (events_[i].kind == Event::GAP && events_[i].newline) return true;
  }
  return false;
}

bool SelectedPlan::can_select(LayoutGap gap, GapState state) const {
  const Event& event = gap_event(gap);
  ASSERT(event.kind == Event::GAP);
  return state == GapState::FLAT ? event.can_flat : event.can_newline;
}

bool SelectedPlan::is_selected(LayoutGap gap, GapState state) const {
  ASSERT(can_select(gap, state));
  return gap_event(gap).newline == (state == GapState::NEWLINE);
}

FinalPlan SelectedPlan::freeze() && { return FinalPlan(std::move(*this)); }

void PlanInsertions::insert_before(LayoutMarker marker,
                                   const std::string& text) {
  ASSERT(marker.is_valid());
  ASSERT(text.find('\n') == std::string::npos);
  insertions_[marker.id_].before.push_back(text);
}

void PlanInsertions::insert_after(LayoutMarker marker,
                                  const std::string& text) {
  ASSERT(marker.is_valid());
  ASSERT(text.find('\n') == std::string::npos);
  insertions_[marker.id_].after.push_back(text);
}

const PlanInsertions::AtMarker* PlanInsertions::at(LayoutMarker marker) const {
  auto found = insertions_.find(marker.id_);
  return found == insertions_.end() ? null : &found->second;
}

SelectedPlan select_layout(Layout* root, int preferred_width) {
  return LayoutSelector(preferred_width).select(root);
}

std::string render_plan(const FinalPlan& plan,
                        const PlanInsertions& insertions) {
  std::string result;
  for (const SelectedPlan::Event& event : plan.selected_.events_) {
    switch (event.kind) {
    case SelectedPlan::Event::TEXT:
      result += event.text;
      break;
    case SelectedPlan::Event::GAP:
      if (event.newline) {
        result += '\n';
        result.append(event.indentation, ' ');
      } else {
        result += event.text;
      }
      break;
    case SelectedPlan::Event::MARK: {
      const PlanInsertions::AtMarker* found = insertions.at(event.marker);
      if (found == null) break;
      for (const std::string& text : found->before)
        result += text;
      for (const std::string& text : found->after)
        result += text;
      break;
    }
    default:
      UNREACHABLE();
    }
  }
  return result;
}

} // namespace compiler
} // namespace toit
