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

#include "queryable_class.h"
#include "set.h"

namespace toit {
namespace compiler {

using namespace ir;

namespace {

class CallSelectorVisitor : public ir::TraversingVisitor {
 public:
  UnorderedMap<Symbol, Set<CallShape>> selectors;

  void visit_CallVirtual(ir::CallVirtual* node) {
    TraversingVisitor::visit_CallVirtual(node);
    selectors[node->selector()].insert(node->shape());
  }
};

} // namespace anonymous

UnorderedMap<Class*, QueryableClass> build_queryables_from_plain_shapes(List<Class*> classes) {
  UnorderedMap<Class*, QueryableClass> result;
  for (auto klass : classes) {
    QueryableClass::SelectorMap methods;

    if (klass->super() != null) {
      // We know we already dealt with the super, because the classes are sorted
      //   by inheritance.
      // Insert the superclass methods first, and then overwrite the ones that this class has.
      methods.add_all(result[klass->super()].methods());
    }
    for (auto method : klass->methods()) {
      Selector<PlainShape> selector(method->name(), method->plain_shape());
      methods[selector] = method;
    }

    result[klass] = QueryableClass(klass, methods);
  }
  return result;
}

UnorderedMap<Class*, QueryableClass> build_queryables_from_resolution_shapes(Program* program) {
  CallSelectorVisitor visitor;
  program->accept(&visitor);
  auto invoked_selectors = visitor.selectors;

  UnorderedMap<Class*, QueryableClass> result;

  for (auto klass : program->classes()) {
    QueryableClass::SelectorMap methods;

    if (klass->super() != null) {
      // We know we already dealt with the super, because the classes are sorted
      //   by inheritance.
      // Insert the superclass methods first, and then overwrite the ones that this class has.
      methods.add_all(result[klass->super()].methods());
    }

    for (auto method : klass->methods()) {
      auto name = method->name();
      auto method_shape = method->resolution_shape();
      auto plain_shape = method_shape.to_plain_shape();

      if (!method_shape.has_optional_parameters()) {
        // No need to see which versions of the method-shape are needed.
        Selector<PlainShape> selector(name, plain_shape);
        methods[selector] = method;
        continue;
      }

      auto probe = invoked_selectors.find(name);
      if (probe == invoked_selectors.end()) {
        // Not called at all. We can just ignore it.
        continue;
      }

      for (auto call_shape : probe->second) {
        if (method_shape.accepts(call_shape)) {
          Selector<PlainShape> selector(name, call_shape.to_plain_shape());
          methods[selector] = method;
        }
      }
    }

    result[klass] = QueryableClass(klass, methods);
  }
  return result;
}

} // namespace toit::compiler
} // namespace toit
