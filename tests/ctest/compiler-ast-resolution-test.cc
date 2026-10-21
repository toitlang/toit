// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/compiler/ast.h"
#include "../../src/compiler/resolution.h"
#include "../../src/compiler/resolver_scope.h"

namespace toit {
namespace compiler {

static void check(bool condition) {
  if (!condition) FATAL("AST resolution test failed");
}

class LiteralVisitor : public resolution::TraversingVisitor {
 public:
  void visit_LiteralInteger(resolution::LiteralIntegerView node) override {
    syntax = node.syntax();
    value = node->value();
  }
  void visit_LibraryPrefix(resolution::LibraryPrefixView node) override {
    syntax = node.syntax();
    prefix = node->prefix();
  }
  ImportScope* prefix = null;
  ast::Node* syntax = null;
  int64 value = 0;
};

static void test() {
  AllowThrowingNew allow;
  Zone zone;
  auto range = Source::Range::invalid();
  ast::LiteralInteger source(Symbol::synthetic("42"));
  ast::LiteralNull nested;
  resolution::LiteralIntegerView integer;
  {
    resolution::Origin origin(&source);
    integer = resolution::make<resolution::LiteralIntegerInfo>(42, range);
    integer->ast_node()->attach(&source);
    {
      resolution::Origin child(&nested);
      auto value = resolution::make<resolution::LiteralNullInfo>(range);
      check(value->ast_node()->syntax() == &nested);
    }
    // An implicit operation keeps the enclosing syntax after a child resolves.
    auto implicit = resolution::make<resolution::NopInfo>(range);
    check(implicit->ast_node()->syntax() == &source);
  }
  check(resolution::Origin::current() == null);
  static_assert(sizeof(resolution::LiteralIntegerView) == sizeof(void*),
                "Typed AST views must remain a single pointer");
  resolution::LiteralIntegerView first(source.resolution());
  check(first.syntax() == &source && first->value() == 42);
  LiteralVisitor visitor;
  visitor.visit(source.resolution());
  check(visitor.syntax == &source && visitor.value == 42);

  // A second resolution updates the AST attachment, not existing views.
  auto second = resolution::make<resolution::LiteralIntegerInfo>(43, range);
  second->ast_node()->attach(&source);
  visitor.visit(source.resolution());
  check(visitor.value == 43);
  check(first.node() == integer->ast_node() && first->value() == 42);

  auto prefix_name = Symbol::synthetic("library");
  ImportScope imports(prefix_name);
  SimpleScope scope(null);
  scope.add(prefix_name, ResolutionEntry(&imports));
  ast::Identifier prefix_identifier(prefix_name);
  ast::Identifier member(Symbol::synthetic("member"));
  ast::Dot qualified(&prefix_identifier, &member);
  check(scope.is_prefixed_identifier(&qualified));
  auto prefix_node = prefix_identifier.resolution();
  visitor.visit(prefix_node);
  check(visitor.prefix == &imports && visitor.syntax == &prefix_identifier);
  check(scope.is_prefixed_identifier(&qualified));
  check(prefix_identifier.resolution() == prefix_node);

  // Re-resolution must respect shadowing even for the same source identifier.
  auto local = resolution::make<resolution::LocalInfo>(prefix_name, false, false, range);
  scope.add(prefix_name, ResolutionEntry(local));
  check(!scope.is_prefixed_identifier(&qualified));
  check(prefix_identifier.resolution() == null);
  // Existing interpretations still retain their own meaning.
  check(resolution::LibraryPrefixView(prefix_node)->prefix() == &imports);
}

} // namespace toit::compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::compiler::test();
  return 0;
}
