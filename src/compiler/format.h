// Copyright (C) 2025 Toit contributors.
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

#include <climits>
#include <string>

#include "scanner.h"
#include "list.h"

namespace toit {
namespace compiler {

namespace ast {
class Unit;
}

namespace format {

static const int FLAT_WIDTH_MAX = INT_MAX / 2;

class Document {
 public:
  enum Type { TEXT, LINE, CONCAT, GROUP, INDENT };
  Type type() const { return type_; }
  int flat_width() const { return flat_width_; }

 protected:
  Document(Type type, int flat_width) : type_(type), flat_width_(flat_width) {}

 private:
  Type type_;
  int flat_width_;
};

/// A literal text node.
/// If the text contains a newline, flat_width is FLAT_WIDTH_MAX — the node
/// cannot be meaningfully rendered on a single line.
class Text : public Document {
 public:
  explicit Text(const std::string& text)
      : Document(TEXT, compute_flat_width(text)), text_(text) {}
  const std::string& text() const { return text_; }

 private:
  std::string text_;

  static int compute_flat_width(const std::string& text) {
    if (text.find('\n') != std::string::npos) return FLAT_WIDTH_MAX;
    return text.length();
  }
};

/// A line break. SOFT becomes a space when flat, a newline when broken.
/// HARD always becomes a newline.
class Line : public Document {
 public:
  enum Kind { SOFT, HARD };
  explicit Line(Kind kind = SOFT)
      : Document(LINE, kind == HARD ? FLAT_WIDTH_MAX : 1),
        kind_(kind) {}
  Kind kind() const { return kind_; }

 private:
  Kind kind_;
};

/// Concatenation of children without break semantics.
/// Lines inside a Concat respond to the nearest enclosing Group.
class Concat : public Document {
 public:
  explicit Concat(List<Document*> children)
      : Document(CONCAT, sum_flat_widths(children)),
        children_(children) {}
  List<Document*> children() const { return children_; }

 private:
  List<Document*> children_;

  static int sum_flat_widths(List<Document*> children) {
    int total = 0;
    for (auto child : children) {
      if (child->flat_width() >= FLAT_WIDTH_MAX - total) return FLAT_WIDTH_MAX;
      total += child->flat_width();
    }
    return total;
  }
};

/// A group that decides whether to render flat or broken.
/// When flat, SOFT Lines become spaces. When broken, they become newlines.
class Group : public Document {
 public:
  explicit Group(List<Document*> children)
      : Document(GROUP, sum_flat_widths(children)),
        children_(children) {}
  List<Document*> children() const { return children_; }

 private:
  List<Document*> children_;

  static int sum_flat_widths(List<Document*> children) {
    int total = 0;
    for (auto child : children) {
      if (child->flat_width() >= FLAT_WIDTH_MAX - total) return FLAT_WIDTH_MAX;
      total += child->flat_width();
    }
    return total;
  }
};

/// Increases indentation for Lines inside its child.
class Indent : public Document {
 public:
  Indent(Document* child, int amount = 2)
      : Document(INDENT, child->flat_width()),
        child_(child), amount_(amount) {}
  Document* child() const { return child_; }
  int amount() const { return amount_; }

 private:
  Document* child_;
  int amount_;
};

} // namespace format

uint8* format_unit(ast::Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size);

} // namespace toit::compiler
} // namespace toit
