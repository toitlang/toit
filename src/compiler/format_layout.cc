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

#include "format_layout.h"

#include <limits>

namespace toit {
namespace compiler {

static const int INFINITE_WIDTH = std::numeric_limits<int>::max() / 2;

LayoutBuilder::~LayoutBuilder() {
  for (auto layout : all_)
    delete layout;
}

Layout *LayoutBuilder::make(Layout::Kind kind) {
  Layout *layout = new Layout(kind);
  all_.push_back(layout);
  return layout;
}

Layout *LayoutBuilder::text(std::string s) {
  ASSERT(s.find('\n') == std::string::npos);
  Layout *layout = make(Layout::TEXT);
  layout->text_ = std::move(s);
  return layout;
}

Layout *LayoutBuilder::unmeasured_text(std::string s) {
  Layout *layout = text(std::move(s));
  layout->flat_width_ = 0;
  return layout;
}

Layout *LayoutBuilder::verbatim(std::string s, int original_column) {
  Layout *layout = make(Layout::VERBATIM);
  layout->text_ = std::move(s);
  layout->original_column_ = original_column;
  return layout;
}

Layout *LayoutBuilder::concat(std::vector<Layout *> children) {
  Layout *layout = make(Layout::CONCAT);
  layout->children_ = std::move(children);
  return layout;
}

Layout *LayoutBuilder::group(Layout *child, int budget, int alternative_lines) {
  Layout *layout = make(Layout::GROUP);
  layout->children_.push_back(child);
  layout->budget_ = budget;
  layout->alternative_lines_ = alternative_lines;
  return layout;
}

Layout *LayoutBuilder::indent(int delta, Layout *child) {
  Layout *layout = make(Layout::INDENT);
  layout->children_.push_back(child);
  layout->indent_delta_ = delta;
  return layout;
}

Layout *LayoutBuilder::line() {
  Layout *layout = make(Layout::LINE);
  layout->text_ = " ";
  return layout;
}

Layout *LayoutBuilder::softline() { return make(Layout::SOFTLINE); }

Layout *LayoutBuilder::hardline() { return make(Layout::HARDLINE); }

Layout *LayoutBuilder::break_parent() { return make(Layout::BREAK_PARENT); }

Layout *LayoutBuilder::blank_lines(int count) {
  std::vector<Layout *> lines;
  for (int i = 0; i < count + 1; i++)
    lines.push_back(hardline());
  return concat(std::move(lines));
}

Layout *LayoutBuilder::if_broken(Layout *broken, Layout *flat) {
  Layout *layout = make(Layout::IF_BROKEN);
  layout->children_.push_back(broken);
  layout->children_.push_back(flat);
  return layout;
}

Layout *LayoutBuilder::choice(Layout *preferred, Layout *fallback) {
  Layout *layout = make(Layout::CHOICE);
  layout->children_.push_back(preferred);
  layout->children_.push_back(fallback);
  return layout;
}

Layout *LayoutBuilder::nil() { return text(""); }

Layout *LayoutBuilder::track(Layout *layout, std::vector<int> emission_ids) {
  layout->emission_ids_ = std::move(emission_ids);
  return layout;
}

// Approximate source width by counting UTF-8 code points. This deliberately
// avoids byte-counting non-ASCII source, but it is not terminal wcwidth:
// combining marks and double-width glyphs still count as one.
static int utf8_code_point_count(const std::string &s) {
  int width = 0;
  for (unsigned char c : s) {
    if ((c & 0xc0) != 0x80)
      width++;
  }
  return width;
}

// Single-line width of `layout`, memoized. INFINITE_WIDTH when the layout
// contains a HARDLINE or a multi-line VERBATIM.
int LayoutBuilder::measure_flat(const Layout *layout) {
  if (layout->flat_width_ >= 0)
    return layout->flat_width_;
  int width = 0;
  switch (layout->kind()) {
  case Layout::TEXT:
    width = utf8_code_point_count(layout->text());
    break;
  case Layout::VERBATIM:
    width = layout->text().find('\n') == std::string::npos
                ? utf8_code_point_count(layout->text())
                : INFINITE_WIDTH;
    break;
  case Layout::CONCAT:
    for (auto child : layout->children()) {
      width += measure_flat(child);
      if (width >= INFINITE_WIDTH) {
        width = INFINITE_WIDTH;
        break;
      }
    }
    break;
  // A group nested in a flat context renders flat as well.
  case Layout::GROUP:
  case Layout::INDENT:
    width = measure_flat(layout->child());
    break;
  case Layout::LINE:
    width = utf8_code_point_count(layout->text());
    break;
  case Layout::SOFTLINE:
    width = 0;
    break;
  case Layout::HARDLINE:
  case Layout::BREAK_PARENT:
    width = INFINITE_WIDTH;
    break;
  case Layout::IF_BROKEN:
    width = measure_flat(layout->flat_alternative());
    break;
  case Layout::CHOICE:
    width = measure_flat(layout->preferred_alternative());
    break;
  }
  layout->flat_width_ = width;
  return width;
}

bool LayoutBuilder::has_finite_flat(const Layout *layout) {
  return measure_flat(layout) < INFINITE_WIDTH;
}

class LayoutPrinter {
public:
  LayoutPrinter(const FormatStyle &style, int base_indent,
                std::vector<int> *emitted_ids)
      : style_(style), column_(base_indent), pending_indent_(-1),
        emitted_ids_(emitted_ids) {}

  std::string take_output() { return std::move(out_); }

  void print(const Layout *layout, int indent, bool flat) {
    if (emitted_ids_ != null) {
      for (int id : layout->emission_ids())
        emitted_ids_->push_back(id);
    }
    switch (layout->kind()) {
    case Layout::TEXT:
      emit_text(layout->text());
      break;
    case Layout::VERBATIM:
      emit_verbatim(layout->text(), layout->original_column());
      break;
    case Layout::CONCAT:
      for (auto child : layout->children())
        print(child, indent, flat);
      break;
    case Layout::GROUP: {
      bool child_flat = flat || fits(layout);
      print(layout->child(), indent, child_flat);
      break;
    }
    case Layout::INDENT:
      print(layout->child(), indent + layout->indent_delta(), flat);
      break;
    case Layout::LINE:
      if (flat) {
        emit_text(layout->text());
      } else {
        emit_newline(indent);
      }
      break;
    case Layout::SOFTLINE:
      if (!flat)
        emit_newline(indent);
      break;
    case Layout::HARDLINE:
      // A hardline inside a flat group cannot happen: flat_width is
      // infinite, so fits() refused, and lowering must not put a
      // hardline inside an if_broken flat alternative.
      ASSERT(!flat);
      emit_newline(indent);
      break;
    case Layout::BREAK_PARENT:
      ASSERT(!flat);
      break;
    case Layout::IF_BROKEN:
      print(flat ? layout->flat_alternative() : layout->broken_alternative(),
            indent, flat);
      break;
    case Layout::CHOICE:
      print(choose(layout, indent, flat), indent, flat);
      break;
    }
  }

private:
  const FormatStyle &style_;
  std::string out_;
  int column_;
  // Indentation to emit before the next visible text; -1 when the
  // current line already has content. Deferring it keeps blank lines
  // free of trailing whitespace.
  int pending_indent_;
  std::vector<int> *emitted_ids_;

  const Layout *choose(const Layout *layout, int indent, bool flat) {
    int preferred_cost = rendered_cost(
        layout->preferred_alternative(), indent, flat);
    int fallback_cost = rendered_cost(
        layout->fallback_alternative(), indent, flat);
    return preferred_cost <= fallback_cost
        ? layout->preferred_alternative()
        : layout->fallback_alternative();
  }

  // Compare complete rendered alternatives. Previewing is side-effect free:
  // emitted comment ids are disabled in the copy. Overflow dominates line
  // count, and line count dominates output size; ties prefer the first shape.
  int rendered_cost(const Layout *layout, int indent, bool flat) {
    LayoutPrinter preview = *this;
    preview.emitted_ids_ = null;
    size_t original_size = preview.out_.size();
    preview.print(layout, indent, flat);

    int lines = 0;
    int overflow = 0;
    int column = 0;
    for (char c : preview.out_) {
      if (c == '\n') {
        lines++;
        if (column > style_.preferred_extent) {
          overflow += column - style_.preferred_extent;
        }
        column = 0;
      } else {
        column++;
      }
    }
    if (column > style_.preferred_extent) {
      overflow += column - style_.preferred_extent;
    }
    int added_size = static_cast<int>(preview.out_.size() - original_size);
    return overflow * 10000 + lines * 100 + added_size;
  }

  // Whether `layout` fits as a flat group. For example, a 100-column group at
  // indentation 8 gets two columns of pressure with the default divisor 4.
  // A broken form with six lines gets four lines above the default threshold;
  // at two columns each, that buys eight columns back. The result is a
  // preference, not an absolute maximum line width.
  bool fits(const Layout *layout) {
    int width = LayoutBuilder::measure_flat(layout);
    if (getenv("TOIT_FORMAT_DEBUG_FITS") != null) {
      int start_col = pending_indent_ >= 0 ? pending_indent_ : column_;
      fprintf(stderr, "fits? width=%d start=%d budget=%d\n", width, start_col,
              layout->budget());
    }
    if (width >= INFINITE_WIDTH)
      return false;
    int budget =
        layout->budget() >= 0 ? layout->budget() : style_.preferred_extent;
    int start_column = pending_indent_ >= 0 ? pending_indent_ : column_;
    int pressure = style_.indentation_pressure_divisor <= 0
                       ? 0
                       : start_column / style_.indentation_pressure_divisor;
    int costly_lines =
        layout->alternative_lines() - style_.alternative_line_threshold;
    if (costly_lines < 0)
      costly_lines = 0;
    int alternative_allowance = costly_lines * style_.alternative_line_extent;
    return width <= budget - pressure + alternative_allowance;
  }

  void flush_indent() {
    if (pending_indent_ < 0)
      return;
    out_.append(pending_indent_, ' ');
    column_ = pending_indent_;
    pending_indent_ = -1;
  }

  void emit_text(const std::string &text) {
    if (text.empty())
      return;
    flush_indent();
    out_.append(text);
    column_ += utf8_code_point_count(text);
  }

  void emit_newline(int indent) {
    out_.push_back('\n');
    pending_indent_ = indent;
    column_ = 0;
  }

  void emit_verbatim(const std::string &text, int original_column) {
    if (text.empty())
      return;
    int start_column = pending_indent_ >= 0 ? pending_indent_ : column_;
    // Interior lines follow the first line's movement; -1 pins them.
    int delta = original_column >= 0 ? start_column - original_column : 0;
    flush_indent();
    size_t start = 0;
    bool first = true;
    while (true) {
      size_t newline = text.find('\n', start);
      size_t line_end = newline == std::string::npos ? text.size() : newline;
      if (!first && delta != 0) {
        // Shift the line's leading whitespace by delta; never into
        // negative indentation, and leave blank lines empty.
        size_t content = start;
        while (content < line_end &&
               (text[content] == ' ' || text[content] == '\t')) {
          content++;
        }
        if (content < line_end) {
          int indent = static_cast<int>(content - start) + delta;
          out_.append(indent < 0 ? 0 : indent, ' ');
        }
        out_.append(text, content, line_end - content);
      } else {
        out_.append(text, start, line_end - start);
      }
      if (newline == std::string::npos)
        break;
      out_.push_back('\n');
      first = false;
      start = newline + 1;
    }
    // Track the column of the last emitted line.
    size_t last_newline = out_.rfind('\n');
    std::string last_line = last_newline == std::string::npos
                                ? out_
                                : out_.substr(last_newline + 1);
    column_ = utf8_code_point_count(last_line);
  }
};

std::string render_layout(const Layout *layout, int base_indent,
                          const FormatStyle &style,
                          std::vector<int> *emitted_ids) {
  LayoutPrinter printer(style, base_indent, emitted_ids);
  printer.print(layout, base_indent, false);
  return printer.take_output();
}

} // namespace compiler
} // namespace toit
