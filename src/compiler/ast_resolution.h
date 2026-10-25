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

#include <type_traits>

#include "../top.h"

namespace toit {
namespace compiler {

namespace ast { class Node; }

namespace resolution {

class Node;
class Type;
class Visitor;
template<typename T> class ReturningVisitor;

// Source syntax together with the semantic information for one interpretation.
// Implicit operations can share the syntax that caused them. No synthetic syntax
// is needed to describe, for example, an implicit receiver or argument temporary.
class AstNode {
 public:
  AstNode(ast::Node* syntax, Node* information)
      : syntax_(syntax), information_(information) {}

  ast::Node* syntax() const { return syntax_; }
  Node* information() const { return information_; }

  // Attaches the result to its source node. Re-resolution replaces the source's
  // current result without changing previously constructed interpretations.
  void attach(ast::Node* syntax);

  void accept(Visitor* visitor);
  Type accept(ReturningVisitor<Type>* visitor);

 private:
  ast::Node* syntax_;
  Node* information_;
};

// A typed, non-owning view of an AST interpretation. Constructing or copying a
// view never allocates; visitors can retain the semantic APIs they need without
// requiring a separate hierarchy of AST nodes.
template<typename Information>
class View {
 public:
  explicit View(AstNode* node) : node_(node) { Information::cast(node->information()); }
  View(Information* information) : node_(information->ast_node()) {}

  template<typename Other,
           typename = typename std::enable_if<std::is_base_of<Information, Other>::value>::type>
  View(const View<Other>& other) : node_(other.node()) {}

  // Transitional conversion for consumers that still store the legacy records.
  operator Information*() const { return operator->(); }

  AstNode* node() const { return node_; }
  ast::Node* syntax() const { return node_->syntax(); }
  Information* operator->() const { return Information::cast(node_->information()); }

 private:
  AstNode* node_;
};

// Records the source of implicit operations while resolving a piece of syntax.
// Nested expressions restore their enclosing source when they finish.
class Origin {
 public:
  explicit Origin(ast::Node* syntax) : previous_(current_) { current_ = syntax; }
  ~Origin() { current_ = previous_; }
  Origin(const Origin&) = delete;
  Origin& operator=(const Origin&) = delete;

  static ast::Node* current() { return current_; }

 private:
  ast::Node* previous_;
  static thread_local ast::Node* current_;
};

} // namespace toit::compiler::resolution
} // namespace toit::compiler
} // namespace toit
