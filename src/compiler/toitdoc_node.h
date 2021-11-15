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
      : _sections(sections) { }
  IMPLEMENTS(Contents)

  List<Section*> sections() const { return _sections; }

 private:
  List<Section*> _sections;
};

class Section : public Node {
 public:
  /// The title may be invalid, if it's the first section of a comment.
  Section(Symbol title, List<Statement*> statements)
      : _title(title)
      , _statements(statements) { }
  IMPLEMENTS(Section)

  Symbol title() const { return _title; }
  List<Statement*> statements() const { return _statements; }

 private:
  Symbol _title;
  List<Statement*> _statements;
};

class Statement : public Node {
 public:
  IMPLEMENTS(Statement)
};

class CodeSection : public Statement {
 public:
  explicit CodeSection(Symbol code)
      : _code(code) { }
  IMPLEMENTS(CodeSection);

  Symbol code() const { return _code; }

 private:
  Symbol _code;
};

class Itemized : public Statement {
 public:
  explicit Itemized(List<Item*> items)
      : _items(items) { }
  IMPLEMENTS(Itemized);

  List<Item*> items() const { return _items; }

 private:
  List<Item*> _items;
};

class Item : public Statement {
 public:
  explicit Item(List<Statement*> statements)
      : _statements(statements) { }
  IMPLEMENTS(Item);

  List<Statement*> statements() const { return _statements; }

 private:
  List<Statement*> _statements;
};

class Paragraph : public Statement {
 public:
  explicit Paragraph(List<Expression*> expressions)
      : _expressions(expressions) { }
  IMPLEMENTS(Paragraph);

  List<Expression*> expressions() const { return _expressions; }
 private:
  List<Expression*> _expressions;
};

class Expression : public Node {
 public:
  IMPLEMENTS(Expression);
};

class Text : public Expression {
 public:
  explicit Text(Symbol text)
      : _text(text) { }
  IMPLEMENTS(Text);

  Symbol text() const { return _text; }

 private:
  Symbol _text;
};

class Code : public Expression {
 public:
  explicit Code(Symbol text)
      : _text(text) { }
  IMPLEMENTS(Code);

  Symbol text() const { return _text; }

 private:
  Symbol _text;
};

class Ref : public Expression {
 public:
  Ref(int id, Symbol text)
      : _id(id)
      , _text(text) { }
  IMPLEMENTS(Ref);

  int id() const { return _id; }
  Symbol text() const { return _text; }

 private:
  int _id;
  Symbol _text;
};

#undef IMPLEMENTS

} // namespace toit::compiler::toitdoc
} // namespace toit::compiler
} // namespace toit
