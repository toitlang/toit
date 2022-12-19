// Copyright (C) 2018 Toitware ApS.
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

#include "optimizations.h"

#include "constant_propagation.h"
#include "dead_code.h"
#include "virtual_call.h"
#include "return_peephole.h"
#include "simplify_sequence.h"
#include "typecheck.h"

#include "../queryable_class.h"
#include "../resolver_scope.h"
#include "../set.h"

namespace toit {
namespace compiler {

using namespace ir;

class OptimizationVisitor : public ReplacingVisitor {
 public:
  OptimizationVisitor(TypeDatabase* propagated_types,
                      const UnorderedMap<Class*, QueryableClass> queryables,
                      const UnorderedSet<Symbol>& field_names)
      : propagated_types_(propagated_types)
      , holder_(null)
      , method_(null)
      , queryables_(queryables)
      , field_names_(field_names) {}

  Node* visit_Method(Method* node) {
    if (propagated_types_ && propagated_types_->is_dead(node)) {
      node->kill();
      return node;
    }
    method_ = node;
    eliminate_dead_code(node, null);
    Node* result = ReplacingVisitor::visit_Method(node);
    eliminate_dead_code(node, propagated_types_);
    method_ = null;
    return result;
  }

  /// Transforms virtual calls into static calls (when possible).
  /// Transforms virtual getters/setters into field accesses (when possible).
  Node* visit_CallVirtual(CallVirtual* node) {
    node = ReplacingVisitor::visit_CallVirtual(node)->as_CallVirtual();
    return optimize_virtual_call(node, holder_, method_, field_names_, queryables_);
  }

  /// Pushes `return`s into `if`s.
  Node* visit_Return(Return* node) {
    node = ReplacingVisitor::visit_Return(node)->as_Return();
    return return_peephole(node);
  }

  /// ...
  Node* visit_Sequence(Sequence* node) {
    node = ReplacingVisitor::visit_Sequence(node)->as_Sequence();
    return simplify_sequence(node);
  }

  Node* visit_Typecheck(Typecheck* node) {
    node = ReplacingVisitor::visit_Typecheck(node)->as_Typecheck();
    return optimize_typecheck(node, holder_, method_);
  }

  Node* visit_Super(Super* node) {
    node = ReplacingVisitor::visit_Super(node)->as_Super();
    if (node->expression() == null) return _new Nop(node->range());
    return node->expression();
  }

  void set_class(Class* klass) { holder_ = klass; }

 private:
  TypeDatabase* const propagated_types_;

  Class* holder_;  // Null, if not in class (or a static method/field).
  Method* method_;
  UnorderedMap<Class*, QueryableClass> queryables_;
  UnorderedSet<Symbol> field_names_;
};

void optimize(Program* program, TypeDatabase* propagated_types) {
  // The constant propagation runs independently, as it builds up its own
  // dependency graph.
  propagate_constants(program);

  auto classes = program->classes();
  auto queryables = build_queryables_from_plain_shapes(classes);

  UnorderedSet<Symbol> field_names;

  // Runs through all classes for two purposes:
  // 1. get all selectors that could be field accesses.
  // 2. nuke members that are overridden. Those cannot be made to direct calls.
  for (auto klass : classes) {
    for (auto method : klass->methods()) {
      Selector<PlainShape> selector(method->name(), method->plain_shape());

      // Get all selectors that could potentially be field accesses.
      if (method->is_FieldStub()) field_names.insert(selector.name());

      // Nuke members in the superclass if they have been overridden.
      auto current = klass->super();
      while (current != null) {
        auto& queryable = queryables[current];
        bool was_present = queryable.remove(selector);
        // No need to go further if the super didn't have it.
        if (!was_present) break;
        current = current->super();
      }
    }
  }

  OptimizationVisitor visitor(propagated_types, queryables, field_names);

  for (auto klass : classes) {
    visitor.set_class(klass);
    // We need to handle constructors (named and unnamed) here, as we use a
    //   different visitor, than for the globals.
    // Unnamed constructors:
    for (auto constructor : klass->constructors()) {
      visitor.visit(constructor);
    }
    // Named constructors are mixed together with the other static entries.
    for (auto statik : klass->statics()->nodes()) {
      if (!statik->is_constructor()) continue;
      visitor.visit(statik);
    }
    for (auto method : klass->methods()) {
      ASSERT(method->is_instance());
      visitor.visit(method);
    }
  }

  visitor.set_class(null);
  for (auto method : program->methods()) {
    if (method->is_constructor()) continue;  // Already handled within the class.
    visitor.visit(method);
  }
  for (auto global : program->globals()) {
    visitor.visit(global);
  }
}


} // namespace toit::compiler
} // namespace toit
