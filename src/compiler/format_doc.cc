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

#include "format_doc.h"

#include <limits>

namespace toit {
namespace compiler {

static const int INFINITE_WIDTH = std::numeric_limits<int>::max() / 2;

DocBuilder::~DocBuilder() {
  for (auto doc : all_) delete doc;
}

Doc* DocBuilder::make(Doc::Kind kind) {
  Doc* doc = new Doc(kind);
  all_.push_back(doc);
  return doc;
}

Doc* DocBuilder::text(std::string s) {
  ASSERT(s.find('\n') == std::string::npos);
  Doc* doc = make(Doc::TEXT);
  doc->text_ = std::move(s);
  return doc;
}

Doc* DocBuilder::verbatim(std::string s, int original_column) {
  Doc* doc = make(Doc::VERBATIM);
  doc->text_ = std::move(s);
  doc->original_column_ = original_column;
  return doc;
}

Doc* DocBuilder::concat(std::vector<Doc*> children) {
  Doc* doc = make(Doc::CONCAT);
  doc->children_ = std::move(children);
  return doc;
}

Doc* DocBuilder::group(Doc* child, int budget) {
  Doc* doc = make(Doc::GROUP);
  doc->children_.push_back(child);
  doc->budget_ = budget;
  return doc;
}

Doc* DocBuilder::indent(int delta, Doc* child) {
  Doc* doc = make(Doc::INDENT);
  doc->children_.push_back(child);
  doc->indent_delta_ = delta;
  return doc;
}

Doc* DocBuilder::line() {
  Doc* doc = make(Doc::LINE);
  doc->text_ = " ";
  return doc;
}

Doc* DocBuilder::softline() {
  return make(Doc::SOFTLINE);
}

Doc* DocBuilder::hardline() {
  return make(Doc::HARDLINE);
}

Doc* DocBuilder::break_parent() {
  return make(Doc::BREAK_PARENT);
}

Doc* DocBuilder::blank_lines(int count) {
  std::vector<Doc*> lines;
  for (int i = 0; i < count + 1; i++) lines.push_back(hardline());
  return concat(std::move(lines));
}

Doc* DocBuilder::if_broken(Doc* broken, Doc* flat) {
  Doc* doc = make(Doc::IF_BROKEN);
  doc->children_.push_back(broken);
  doc->children_.push_back(flat);
  return doc;
}

Doc* DocBuilder::nil() {
  return text("");
}

// Display width of a UTF-8 string in columns. Counts code points
// (continuation bytes 0b10xxxxxx are zero-width); good enough without
// a wcwidth table.
static int utf8_width(const std::string& s) {
  int width = 0;
  for (unsigned char c : s) {
    if ((c & 0xc0) != 0x80) width++;
  }
  return width;
}

class DocPrinter {
 public:
  DocPrinter(const FormatStyle& style, int base_indent)
      : style_(style)
      , column_(base_indent)
      , pending_indent_(-1) {}

  std::string take_output() { return std::move(out_); }

  // Single-line width of `doc`, memoized. INFINITE_WIDTH when the doc
  // contains a HARDLINE or a multi-line VERBATIM.
  static int flat_width(const Doc* doc) {
    if (doc->flat_width_ >= 0) return doc->flat_width_;
    int width = 0;
    switch (doc->kind()) {
      case Doc::TEXT:
        width = utf8_width(doc->text());
        break;
      case Doc::VERBATIM:
        width = doc->text().find('\n') == std::string::npos
            ? utf8_width(doc->text())
            : INFINITE_WIDTH;
        break;
      case Doc::CONCAT:
        for (auto child : doc->children()) {
          width += flat_width(child);
          if (width >= INFINITE_WIDTH) {
            width = INFINITE_WIDTH;
            break;
          }
        }
        break;
      // A group nested in a flat context renders flat as well.
      case Doc::GROUP:
      case Doc::INDENT:
        width = flat_width(doc->child());
        break;
      case Doc::LINE:
        width = utf8_width(doc->text());
        break;
      case Doc::SOFTLINE:
        width = 0;
        break;
      case Doc::HARDLINE:
      case Doc::BREAK_PARENT:
        width = INFINITE_WIDTH;
        break;
      case Doc::IF_BROKEN:
        width = flat_width(doc->flat_alternative());
        break;
    }
    doc->flat_width_ = width;
    return width;
  }

  void print(const Doc* doc, int indent, bool flat) {
    switch (doc->kind()) {
      case Doc::TEXT:
        emit_text(doc->text());
        break;
      case Doc::VERBATIM:
        emit_verbatim(doc->text(), doc->original_column());
        break;
      case Doc::CONCAT:
        for (auto child : doc->children()) print(child, indent, flat);
        break;
      case Doc::GROUP: {
        bool child_flat = flat || fits(doc);
        print(doc->child(), indent, child_flat);
        break;
      }
      case Doc::INDENT:
        print(doc->child(), indent + doc->indent_delta(), flat);
        break;
      case Doc::LINE:
        if (flat) {
          emit_text(doc->text());
        } else {
          emit_newline(indent);
        }
        break;
      case Doc::SOFTLINE:
        if (!flat) emit_newline(indent);
        break;
      case Doc::HARDLINE:
        // A hardline inside a flat group cannot happen: flat_width is
        // infinite, so fits() refused, and lowering must not put a
        // hardline inside an if_broken flat alternative.
        ASSERT(!flat);
        emit_newline(indent);
        break;
      case Doc::BREAK_PARENT:
        ASSERT(!flat);
        break;
      case Doc::IF_BROKEN:
        print(flat ? doc->flat_alternative() : doc->broken_alternative(),
              indent, flat);
        break;
    }
  }

 private:
  const FormatStyle& style_;
  std::string out_;
  int column_;
  // Indentation to emit before the next visible text; -1 when the
  // current line already has content. Deferring it keeps blank lines
  // free of trailing whitespace.
  int pending_indent_;

  // Whether `doc` fits on the current line. Two conditions:
  // node-relative (the group's own extent stays within the budget,
  // independent of where it starts — layout does not change when code
  // moves to a different nesting depth) and the damped absolute
  // backstop (indented code may drift right, but at most `slack`
  // columns past `max_width`).
  bool fits(const Doc* doc) {
    int width = flat_width(doc);
    if (getenv("TOIT_FORMAT_DEBUG_FITS") != null) {
      int start_col = pending_indent_ >= 0 ? pending_indent_ : column_;
      fprintf(stderr, "fits? width=%d start=%d budget=%d\n",
              width, start_col, doc->budget());
    }
    if (width >= INFINITE_WIDTH) return false;
    int budget = doc->budget() >= 0 ? doc->budget() : style_.max_width;
    if (width > budget) return false;
    int start_column = pending_indent_ >= 0 ? pending_indent_ : column_;
    int limit = style_.max_width
        + (start_column < style_.slack ? start_column : style_.slack);
    return start_column + width <= limit;
  }

  void flush_indent() {
    if (pending_indent_ < 0) return;
    out_.append(pending_indent_, ' ');
    column_ = pending_indent_;
    pending_indent_ = -1;
  }

  void emit_text(const std::string& text) {
    if (text.empty()) return;
    flush_indent();
    out_.append(text);
    column_ += utf8_width(text);
  }

  void emit_newline(int indent) {
    out_.push_back('\n');
    pending_indent_ = indent;
    column_ = 0;
  }

  void emit_verbatim(const std::string& text, int original_column) {
    if (text.empty()) return;
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
      if (newline == std::string::npos) break;
      out_.push_back('\n');
      first = false;
      start = newline + 1;
    }
    // Track the column of the last emitted line.
    size_t last_newline = out_.rfind('\n');
    std::string last_line = last_newline == std::string::npos
        ? out_
        : out_.substr(last_newline + 1);
    column_ = utf8_width(last_line);
  }
};

bool doc_has_breakpoints(const Doc* doc) {
  switch (doc->kind()) {
    case Doc::TEXT:
      return false;
    case Doc::VERBATIM:
      return doc->text().find('\n') != std::string::npos;
    case Doc::CONCAT:
      for (auto child : doc->children()) {
        if (doc_has_breakpoints(child)) return true;
      }
      return false;
    case Doc::GROUP:
    case Doc::INDENT:
      return doc_has_breakpoints(doc->child());
    case Doc::LINE:
    case Doc::SOFTLINE:
    case Doc::HARDLINE:
    case Doc::BREAK_PARENT:
      return true;
    case Doc::IF_BROKEN:
      return doc_has_breakpoints(doc->broken_alternative())
          || doc_has_breakpoints(doc->flat_alternative());
  }
  return true;
}

std::string print_doc(const Doc* doc, int base_indent, const FormatStyle& style) {
  DocPrinter printer(style, base_indent);
  printer.print(doc, base_indent, false);
  return printer.take_output();
}

} // namespace toit::compiler
} // namespace toit
