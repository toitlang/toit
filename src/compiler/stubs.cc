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

#include "stubs.h"

#include "selector.h"
#include "set.h"

#include "../utils.h"

namespace toit {
namespace compiler {

class CallSelectorVisitor : public ir::TraversingVisitor {
 public:
  UnorderedMap<Symbol, Set<CallShape>> selectors;

  void visit_CallVirtual(ir::CallVirtual* node) {
    TraversingVisitor::visit_CallVirtual(node);
    selectors[node->selector()].insert(node->shape());
  }
};

void add_stub_methods_and_switch_to_plain_shapes(ir::Program* program) {
  CallSelectorVisitor visitor;
  program->accept(&visitor);
  auto selectors = visitor.selectors;

  for (auto klass : program->classes()) {
    std::vector<ir::AdapterStub*> stubs;
    for (auto method : klass->methods()) {
      auto method_shape = method->resolution_shape();
      auto plain_shape = method_shape.to_plain_shape();

      // Now create stubs, if necessary.

      // If there aren't any optional parameters, no need to create a stub.
      if (!method_shape.has_optional_parameters()) {
        method->set_plain_shape(plain_shape);
        continue;
      }

      // If the function is never used in a virtual call, no need to create a stub.
      auto probe = selectors.find(method->name());
      if (probe == selectors.end()) {
        // Not used through virtual calls.
        // Just switch to plain shape.
        method->set_plain_shape(plain_shape);
        continue;
      }

      auto range = method->range();
      // Run through all call-shapes for the given selector-name and see whether
      // one (or some) of them require stubs.
      for (auto call_shape : probe->second) {
        // If the call_shape is the same as the plain-shape, then the method
        // already matches.
        if (call_shape.to_plain_shape() == plain_shape) continue;
        // If the call shape never works for this method, then the method can't
        // be a valid target for the call.
        if (!method_shape.accepts(call_shape)) continue;

        // Need to create stub-method for this call.
        int source_arity = call_shape.arity();
        auto stub_parameters = ListBuilder<ir::Parameter*>::allocate(source_arity);
        for (int i = 0; i < source_arity; i++) {
          Symbol stub_parameter_name = i == 0
              ? Symbols::this_
              : Symbol::synthetic("<stub-parameter>");
          stub_parameters[i] = _new ir::Parameter(stub_parameter_name,
                                                  ir::Type::any(),  // The types will be updated below.
                                                  call_shape.is_block(i),
                                                  i,
                                                  false,  // Whether it has a default value is updated below.
                                                  range);
        }
        CallBuilder builder(range);
        for (int i = 0; i < source_arity; i++) {
          builder.add_argument(
            _new ir::ReferenceLocal(stub_parameters[i], 0, range),
            call_shape.name_for(i));
        }
        auto forward_call = builder.call_static(_new ir::ReferenceMethod(method, range));

        ASSERT(forward_call->is_CallStatic());
        forward_call->as_CallStatic()->mark_tail_call();

        // Update the types of the forward parameters.
        // We just need to match each arg with the corresponding target-parameter and
        // then work back to the stub-parameter from there.
        auto forward_args = forward_call->as_CallStatic()->arguments();
        auto target_parameters = method->parameters();
        ASSERT(forward_args.length() == target_parameters.length());
        for (int i = 0; i < forward_args.length(); i++) {
          auto forward_arg = forward_args[i];
          if (forward_arg->is_LiteralNull()) continue;  // Filled in default value.
          auto stub_parameter = forward_arg->as_ReferenceLocal()->target()->as_Parameter();
          stub_parameter->set_type(target_parameters[i]->type());
          stub_parameter->set_has_default_value(target_parameters[i]->has_default_value());
        }

        auto stub = _new ir::AdapterStub(method->name(), method->holder(), call_shape.to_plain_shape(), range);
        stub->set_parameters(stub_parameters);
        stub->set_body(_new ir::Return(forward_call, false, range));
        stub->set_return_type(method->return_type());
        stubs.push_back(stub);
      }
      // Switch the original method to instance-method shape.
      method->set_plain_shape(plain_shape);
    }
    if (stubs.empty()) continue;
    ListBuilder<ir::MethodInstance*> method_builder;
    method_builder.add(klass->methods());
    for (auto stub : stubs) method_builder.add(stub);
    klass->replace_methods(method_builder.build());
  }

  for (auto method : program->methods()) {
    method->set_plain_shape(method->resolution_shape().to_plain_shape());
  }
  for (auto global : program->globals()) {
    global->set_plain_shape(global->resolution_shape().to_plain_shape());
  }
}

static CallShape interface_selector_call_shape() {
  return CallShape(0).with_implicit_this();
}

class IsInterfaceVisitor : public ir::TraversingVisitor {
 public:
  void visit_Typecheck(ir::Typecheck* node) {
    TraversingVisitor::visit_Typecheck(node);
    if (node->type().is_any()) return;
    auto klass = node->type().klass();
    if (!klass->is_interface()) return;
    if (klass->typecheck_selector().is_valid()) return;

    // Names might be the same as two modules might have interfaces with
    //   the same name. However, we need to ensure that the Symbol is
    //   different, by pointing to different memory locations.
    int name_len = strlen(klass->name().c_str());
    int fresh_length = 3 + name_len;
    char* fresh_name = unvoid_cast<char*>(malloc(fresh_length + 1));
    memcpy(fresh_name, "is-", 3);
    memcpy(fresh_name + 3, klass->name().c_str(), name_len);
    fresh_name[fresh_length] = '\0';
    Selector<CallShape> selector(Symbol::synthetic(fresh_name),
                                 interface_selector_call_shape());
    klass->set_typecheck_selector(selector);

    // We still need to add stub methods.
    interfaces_to_selectors_.add(klass, selector);
  }

  UnorderedMap<ir::Class*, Selector<CallShape>> interfaces_to_selectors() const {
    return interfaces_to_selectors_;
  }

 private:
  // We have to use `const char*` since we don't have a default constructor for
  // symbols.
  UnorderedMap<ir::Class*, Selector<CallShape>> interfaces_to_selectors_;
};

void add_interface_stub_methods(ir::Program* program) {
  IsInterfaceVisitor visitor;
  program->accept(&visitor);

  auto interfaces_to_selectors = visitor.interfaces_to_selectors();
  for (auto klass : program->classes()) {
    if (klass->is_interface()) continue;
    if (klass->interfaces().is_empty()) continue;
    ListBuilder<ir::MethodInstance*> new_methods;
    for (auto ir_interface : klass->interfaces()) {
      auto probe = interfaces_to_selectors.find(ir_interface);
      if (probe == interfaces_to_selectors.end()) continue;
      auto selector = probe->second;
      auto stub = _new ir::IsInterfaceStub(selector.name(),
                                           klass,
                                           selector.shape().to_plain_shape(),
                                           klass->range());
      auto this_parameter = _new ir::Parameter(Symbols::this_,
                                               ir::Type::any(),
                                               false,
                                               0,
                                               false,
                                               stub->range());
      auto parameters = ListBuilder<ir::Parameter*>::build(this_parameter);
      stub->set_parameters(parameters);
      // TODO(florian): this should be type boolean.
      stub->set_return_type(ir::Type::any());
      // The body should never get compiled, but this makes it easier to deal
      // with the stub.
      stub->set_body(_new ir::Return(_new ir::LiteralBoolean(true, stub->range()), false, stub->range()));
      new_methods.add(stub);
    }
    if (new_methods.is_empty()) continue;
    new_methods.add(klass->methods());
    klass->replace_methods(new_methods.build());
  }
}

} // namespace toit::compiler
} // namespace toit
