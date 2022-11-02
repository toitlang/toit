// Copyright (C) 2019 Toitware ApS.
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

#include "ast.h"
#include "list.h"
#include "sources.h"
#include "symbol.h"
#include "token.h"

namespace toit {
namespace compiler {
namespace toitdoc {

class Node;

#define TOITDOC_NODES(V)                \
  V(Contents)                   \
  V(Section)                    \
  V(Statement)                  \
  V(CodeSection)                \
  V(Itemized)                   \
  V(Item)                       \
  V(Paragraph)                  \
  V(Expression)                 \
  V(Text)                       \
  V(Code)                       \
  V(Ref)                        \

#define DECLARE(name) class name;
TOITDOC_NODES(DECLARE)
#undef DECLARE

class Visitor {
 public:
  virtual void visit(Node* node);

#define DECLARE(name) virtual void visit_##name(name* node);
TOITDOC_NODES(DECLARE)
#undef DECLARE
};

class Node {
 public:
  virtual void accept(Visitor* visitor) = 0;

#define DECLARE(name)                              \
  virtual bool is_##name() const { return false; } \
  virtual name* as_##name() { return null; }
TOITDOC_NODES(DECLARE)
#undef DECLARE

  virtual const char* node_type() const { return "Node"; }
};

#define IMPLEMENTS(name)                                                 \
  virtual void accept(Visitor* visitor) { visitor->visit_##name(this); } \
  virtual bool is_##name() const { return true; }                        \
  virtual name* as_##name() { return this; }                             \
  virtual const char* node_type() const { return #name; }

class Contents : public Node {
 public:
  explicit Contents(List<Section*> sections)
      : sections_(sections) { }
  IMPLEMENTS(Contents)

  List<Section*> sections() const { return sections_; }

 private:
  List<Section*> sections_;
};

class Section : public Node {
 public:
  /// The title may be invalid, if it's the first section of a comment.
  Section(Symbol title, List<Statement*> statements)
      : title_(title)
      , statements_(statements) { }
  IMPLEMENTS(Section)

  Symbol title() const { return title_; }
  List<Statement*> statements() const { return statements_; }

 private:
  Symbol title_;
  List<Statement*> statements_;
};

class Statement : public Node {
 public:
  IMPLEMENTS(Statement)
};

class CodeSection : public Statement {
 public:
  explicit CodeSection(Symbol code)
      : code_(code) { }
  IMPLEMENTS(CodeSection);

  Symbol code() const { return code_; }

 private:
  Symbol code_;
};

class Itemized : public Statement {
 public:
  explicit Itemized(List<Item*> items)
      : items_(items) { }
  IMPLEMENTS(Itemized);

  List<Item*> items() const { return items_; }

 private:
  List<Item*> items_;
};

class Item : public Statement {
 public:
  explicit Item(List<Statement*> statements)
      : statements_(statements) { }
  IMPLEMENTS(Item);

  List<Statement*> statements() const { return statements_; }

 private:
  List<Statement*> statements_;
};

class Paragraph : public Statement {
 public:
  explicit Paragraph(List<Expression*> expressions)
      : expressions_(expressions) { }
  IMPLEMENTS(Paragraph);

  List<Expression*> expressions() const { return expressions_; }
 private:
  List<Expression*> expressions_;
};

class Expression : public Node {
 public:
  IMPLEMENTS(Expression);
};

class Text : public Expression {
 public:
  explicit Text(Symbol text)
      : text_(text) { }
  IMPLEMENTS(Text);

  Symbol text() const { return text_; }

 private:
  Symbol text_;
};

class Code : public Expression {
 public:
  explicit Code(Symbol text)
      : text_(text) { }
  IMPLEMENTS(Code);

  Symbol text() const { return text_; }

 private:
  Symbol text_;
};

class Ref : public Expression {
 public:
  Ref(int id, Symbol text)
      : id_(id)
      , text_(text) { }
  IMPLEMENTS(Ref);

  int id() const { return id_; }
  Symbol text() const { return text_; }

 private:
  int id_;
  Symbol text_;
};

#undef IMPLEMENTS

} // namespace toit::compiler::toitdoc
} // namespace toit::compiler
} // namespace toit
