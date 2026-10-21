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

#include <functional>
#include <type_traits>

#include "zone.h"

namespace toit {
namespace compiler {

namespace ast { class Node; }

namespace resolution {

class NodeInfo;
class Type;
class Visitor;
template<typename T> class ReturningVisitor;

// Source syntax together with the semantic information for one interpretation.
// Implicit operations can share the syntax that caused them. No synthetic syntax
// is needed to describe, for example, an implicit receiver or argument temporary.
class AstNode {
 public:
  AstNode(ast::Node* syntax, NodeInfo* information)
      : syntax_(syntax), information_(information) {}

  ast::Node* syntax() const { return syntax_; }
  NodeInfo* information() const { return information_; }

  // Attaches the result to its source node. Re-resolution replaces the source's
  // current result without changing previously constructed interpretations.
  void attach(ast::Node* syntax);

  void accept(Visitor* visitor);
  Type accept(ReturningVisitor<Type>* visitor);

 private:
  ast::Node* syntax_;
  NodeInfo* information_;
};

// A typed, non-owning view of an AST interpretation. Constructing or copying a
// view never allocates; visitors can retain the semantic APIs they need without
// requiring a separate hierarchy of AST nodes.
template<typename Information>
class View {
 public:
  constexpr View() : node_(null) {}
  constexpr View(std::nullptr_t) : node_(null) {}
  explicit View(AstNode* node) : node_(node) {
    if (node != null) Information::cast(node->information());
  }

  template<typename Other,
           typename = typename std::enable_if<std::is_base_of<Information, Other>::value>::type>
  View(const View<Other>& other) : node_(other.node()) {}

  explicit operator bool() const { return node_ != null; }

  bool operator==(std::nullptr_t) const { return node_ == null; }
  bool operator!=(std::nullptr_t) const { return node_ != null; }
  template<typename Other> bool operator==(View<Other> other) const { return node_ == other.node(); }
  template<typename Other> bool operator!=(View<Other> other) const { return node_ != other.node(); }
  template<typename Other> bool operator<(View<Other> other) const {
    return std::less<AstNode*>()(node_, other.node());
  }

  AstNode* node() const { return node_; }
  ast::Node* syntax() const { return node_->syntax(); }
  Information* operator->() const { return Information::cast(node_->information()); }

 private:
  AstNode* node_;
};

template<typename Information, typename... Args>
View<Information> make(Args&&... args) {
  auto information = zone_new<Information>(std::forward<Args>(args)...);
  return View<Information>(information->ast_node());
}

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

namespace std {
  template<typename Information>
  struct hash<toit::compiler::resolution::View<Information>> {
    size_t operator()(toit::compiler::resolution::View<Information> view) const {
      return hash<toit::compiler::resolution::AstNode*>()(view.node());
    }
  };
}
