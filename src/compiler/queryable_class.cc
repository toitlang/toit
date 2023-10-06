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

  ir::Class* object_class = program->classes()[0];
  ASSERT(object_class->name() == Symbols::Object);

  UnorderedMap<Class*, QueryableClass> result;

  for (int i = 0; i < 2; i++) {
    // We run in two phases:
    // The first phase only does mixins.
    // The second the rest.
    for (auto klass : program->classes()) {
      if (i == 0 && !klass->is_mixin()) continue;
      if (i == 1 && klass->is_mixin()) continue;

      QueryableClass::SelectorMap methods;

      if (klass->super() != null) {
        // We know we already dealt with the super, because the classes are sorted
        //   by inheritance.
        // Insert the superclass methods first, and then overwrite the ones that this class has.
        ASSERT(result.find(klass->super()) != result.end());
        methods.add_all(result[klass->super()].methods());
      } else if (klass != object_class) {
        // Interface or Mixin.
        // Add the Object methods as they have to be available for every object.
        methods.add_all(result[object_class].methods());
      }

      for (auto mixin : klass->mixins()) {
        // We do mixins first, and also have sorted mixins in such a way
        // that their "parents" are always first.
        // The mixin must thus already be handled.
        ASSERT(result.find(mixin) != result.end());
        methods.add_all(result[mixin].methods());
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
  }
  return result;
}

} // namespace toit::compiler
} // namespace toit
