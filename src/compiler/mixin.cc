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

static List<ir::Parameter*> duplicate_parameters(List<ir::Parameter*> parameters) {
  auto result = ListBuilder<ir::Parameter*>::allocate(parameters.length());
  for (int i = 0; i < parameters.length(); i++) {
    auto parameter = parameters[i];
    result[i] = _new ir::Parameter(parameter->name(),
                                   parameter->type(),
                                   parameter->is_block(),
                                   parameter->index(),
                                   parameter->has_default_value(),
                                   parameter->range());
  }
  return result;
}

static void apply_mixins(ir::Class* klass) {
  if (klass->mixins().is_empty()) return;

  UnorderedMap<Symbol, UnorderedSet<PlainShape>> existing_methods;
  for (auto method : klass->methods()) {
    existing_methods[method->name()].insert(method->plain_shape());
  }

  Map<ir::Field*, ir::Field*> new_fields;  // From mixin-field to class-field.
  for (auto mixin : klass->mixins()) {
    for (auto field : mixin->fields()) {
      auto new_field = _new ir::Field(field->name(),
                                      klass,
                                      field->is_final(),
                                      field->range());
      new_field->set_type(field->type());
      new_fields[field] = new_field;
    }
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
      auto stub_parameters = duplicate_parameters(original_parameters);
      ir::MethodInstance* stub;
      ir::Expression* body;

      if (method->is_FieldStub() &&
          (method->as_FieldStub()->is_getter() ||
          // If this is the setter for a final field we just forward the call.
          // That's easier than recreating the 'throw' again.
           !method->as_FieldStub()->field()->is_final())) {
        // Mostly a copy of what's happening in `resolver_method`.
        auto range = method->range();
        auto field_stub = method->as_FieldStub();
        auto probe = new_fields.find(field_stub->field());
        ASSERT(probe != new_fields.end());
        auto new_field = probe->second;
        ir::FieldStub* new_field_stub = _new ir::FieldStub(new_field,
                                                           klass,
                                                           field_stub->is_getter(),
                                                           range);
        new_field_stub->set_plain_shape(shape);
        auto this_ref = _new ir::ReferenceLocal(stub_parameters[0], 0, range);
        if (field_stub->is_getter()) {
          ASSERT(stub_parameters.length() == 1);
          auto load = _new ir::FieldLoad(this_ref, new_field, range);
          auto ret = _new ir::Return(load, false, range);
          body = _new ir::Sequence(ListBuilder<ir::Expression*>::build(ret), range);
        } else {
          ASSERT(stub_parameters.length() == 2);
          auto store = _new ir::FieldStore(this_ref,
                                           new_field,
                                           _new ir::ReferenceLocal(stub_parameters[1], 0, range),
                                           range);
          auto ret = _new ir::Return(store, false, range);
          if (!new_field->type().is_class()) {
            body = _new ir::Sequence(ListBuilder<ir::Expression*>::build(ret), range);
          } else {
            auto type = new_field->type();
            new_field_stub->set_checked_type(type);
            auto check = _new ir::Typecheck(ir::Typecheck::PARAMETER_AS_CHECK,
                                            _new ir::ReferenceLocal(stub_parameters[1], 0, range),
                                            type,
                                            type.klass()->name(),
                                            range);
            body = _new ir::Sequence(ListBuilder<ir::Expression*>::build(check, ret), range);
          }
        }
        stub = new_field_stub;
      } else if (method->is_IsInterfaceOrMixinStub()) {
        // We copy over the method (used to determine if a class is an interface or mixin).
        // The body will not be compiled, so it's not important what we put in there.
        auto is_stub = method->as_IsInterfaceOrMixinStub();
        stub = _new ir::IsInterfaceOrMixinStub(method_name,
                                               klass,
                                               shape,
                                               is_stub->interface_or_mixin(),
                                               method->range());

        body = _new ir::Return(_new ir::LiteralBoolean(true, range), false, range);
      } else {
        auto forward_arguments = ListBuilder<ir::Expression*>::allocate(arity);
        for (int i = 0; i < arity; i++) {
          auto stub_parameter = stub_parameters[i];
          forward_arguments[i] = _new ir::ReferenceLocal(stub_parameter, 0, range);
        }

        auto forward_call = _new ir::CallStatic(_new ir::ReferenceMethod(method, range),
                                                shape.to_equivalent_call_shape(),
                                                forward_arguments,
                                                range);

        stub = _new ir::MixinStub(method_name, klass, shape, method->range());
        body = _new ir::Return(forward_call, false, range);
      }
      stub->set_parameters(stub_parameters);
      stub->set_body(body);
      stub->set_return_type(method->return_type());
      if (method->does_not_return()) stub->mark_does_not_return();
      new_stubs.push_back(stub);
      existing_methods[method_name].insert(shape);
    }
  }

  if (!new_fields.empty()) {
    ListBuilder<ir::Field*> field_builder;
    field_builder.add(klass->fields());
    new_fields.for_each([&](ir::Field* key, ir::Field* new_field) {
      field_builder.add(new_field);
    });
    klass->replace_fields(field_builder.build());
  }
  if (!new_stubs.empty()) {
    ListBuilder<ir::MethodInstance*> method_builder;
    method_builder.add(klass->methods());
    for (auto stub : new_stubs) method_builder.add(stub);
    klass->replace_methods(method_builder.build());
  }
}

void apply_mixins(ir::Program* program) {
  for (auto klass : program->classes()) {
    apply_mixins(klass);
  }
}

} // namespace toit::compiler
} // namespace toit
