// Copyright (C) 2023 Toitware ApS.
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

#include <deque>
#include "ir.h"
#include "map.h"
#include "mixin.h"
#include "set.h"
#include "shape.h"

namespace toit {
namespace compiler {

static void add_stubs(ir::Class* klass) {
  if (klass->mixins().is_empty()) return;

  UnorderedMap<Symbol, UnorderedSet<PlainShape>> existing_methods;
  for (auto method : klass->methods()) {
    existing_methods[method->name()].insert(method->plain_shape());
  }

  std::vector<ir::MethodInstance*> new_stubs;

  // We only copy a method if it doesn't exist yet. The mixin list
  // is ordered such that the first mixin shadows methods of later
  // mixins (and super).
  // At this stage, all methods are based on plain-shapes and accept a
  // single selector. That means that we don't need to worry about
  // overlapping methods.
  for (auto mixin : klass->mixins()) {
    for (auto method : mixin->methods()) {
      // Don't create forwarder stubs to mixin stubs.
      // The flattened list of mixins will make sure we get all the methods we need.
      if (method->is_MixinStub()) continue;
      Symbol method_name = method->name();
      PlainShape shape = method->plain_shape();
      Source::Range range = method->range();
      int arity = shape.arity();

      auto probe = existing_methods.find(method_name);
      if (probe != existing_methods.end() && probe->second.contains(shape)) {
        // Already exists.
        continue;
      }
      auto original_parameters = method->parameters();
      ASSERT(original_parameters.length() == arity);
      auto stub_parameters = ListBuilder<ir::Parameter*>::allocate(arity);
      auto forward_arguments = ListBuilder<ir::Expression*>::allocate(arity);
      for (int i = 0; i < arity; i++) {
        auto original_parameter = original_parameters[i];
        ASSERT(original_parameter->index() == i);
        auto stub_parameter = _new ir::Parameter(original_parameter->name(),
                                                 original_parameter->type(),
                                                 original_parameter->is_block(),
                                                 original_parameter->index(),
                                                 original_parameter->has_default_value(),
                                                 original_parameter->range());
        stub_parameters[i] = stub_parameter;
        forward_arguments[i] = _new ir::ReferenceLocal(stub_parameter, 0, range);
      }

      auto forward_call = _new ir::CallStatic(_new ir::ReferenceMethod(method, range),
                                              shape.to_equivalent_call_shape(),
                                              forward_arguments,
                                              range);

      ir::MethodInstance* stub;
      if (method->is_IsInterfaceOrMixinStub()) {
        // We copy over the method (used to determine if a class is an interface or mixin).
        // The body will not be compiled, so it's not important what we put in there.
        auto is_stub = method->as_IsInterfaceOrMixinStub();
        stub = _new ir::IsInterfaceOrMixinStub(method_name,
                                               klass,
                                               shape,
                                               is_stub->interface_or_mixin(),
                                               method->range());
      } else {
        stub = _new ir::MixinStub(method_name, klass, shape, method->range());
      }
      stub->set_parameters(stub_parameters);
      stub->set_body(_new ir::Return(forward_call, false, range));
      stub->set_return_type(method->return_type());
      new_stubs.push_back(stub);
      existing_methods[method_name].insert(shape);
    }
  }
  if (new_stubs.empty()) return;
  ListBuilder<ir::MethodInstance*> method_builder;
  method_builder.add(klass->methods());
  for (auto stub : new_stubs) method_builder.add(stub);
  klass->replace_methods(method_builder.build());
}

void add_mixin_stubs(ir::Program* program) {
  for (auto klass : program->classes()) {
    add_stubs(klass);
  }
}

} // namespace toit::compiler
} // namespace toit
