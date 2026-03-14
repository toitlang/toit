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

#include "scanner.h"
#include "list.h"

namespace toit {
namespace compiler {

namespace ast {
class Unit;
}

namespace format {

class Text;
class Line;
class Indent;
class Group;
class IfFlat;

class Document {
 public:
  enum Type {
    TEXT,
    LINE,
    INDENT,
    GROUP,
    IFFLAT,
  };
  explicit Document(Type type) : type_(type) {}
  virtual ~Document() {}
  Type type() const { return type_; }
 
  // Helpers to avoid dynamic_cast
  Text* as_text() { return reinterpret_cast<Text*>(this); }
  Line* as_line() { return reinterpret_cast<Line*>(this); }
  Indent* as_indent() { return reinterpret_cast<Indent*>(this); }
  Group* as_group() { return reinterpret_cast<Group*>(this); }
  IfFlat* as_if_flat() { return reinterpret_cast<IfFlat*>(this); }
  
 private:
  Type type_;
};

class Text : public Document {
 public:
  explicit Text(const std::string& text) : Document(TEXT), text_(text) {}
  const std::string& text() const { return text_; }
 private:
  std::string text_;
};

class Line : public Document {
 public:
  explicit Line(bool hard_break = false) : Document(LINE), hard_break_(hard_break) {}
  bool is_hard_break() const { return hard_break_; }
 private:
  bool hard_break_;
};

class Indent : public Document {
 public:
  explicit Indent(Document* child, int amount = 2) : Document(INDENT), child_(child), amount_(amount) {}
  Document* child() const { return child_; }
  int amount() const { return amount_; }
 private:
  Document* child_;
  int amount_;
};

class Group : public Document {
 public:
  explicit Group(List<Document*> children) : Document(GROUP), children_(children) {}
  const List<Document*>& children() const { return children_; }
 private:
  List<Document*> children_;
};

class IfFlat : public Document {
 public:
  explicit IfFlat(Document* flat, Document* broken = null) 
      : Document(IFFLAT), flat_(flat), broken_(broken) {}
  Document* flat() const { return flat_; }
  Document* broken() const { return broken_; }
 private:
  Document* flat_;
  Document* broken_;
};

} // namespace format

uint8* format_unit(ast::Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size);

} // namespace toit::compiler
} // namespace toit
