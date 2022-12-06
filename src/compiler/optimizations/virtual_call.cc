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

#include "virtual_call.h"
#include "typecheck.h"
#include "utils.h"

#include "../queryable_class.h"
#include "../set.h"

#include "../../flags.h"
#include "../../bytecodes.h"

namespace toit {
namespace compiler {

using namespace ir;

static Opcode opcode_for(Selector<CallShape> selector) {
  if (selector.name() == Symbols::index_put &&
      selector.shape() == CallShape(2).with_implicit_this()) {
    return INVOKE_AT_PUT;
  }

  // If this isn't a binary, non-setter method, we just treat it as
  // an ordinary virtual invocation.
  if (selector.shape() != CallShape(1).with_implicit_this()) return INVOKE_VIRTUAL;

  auto name = selector.name();
  for (int i = INVOKE_EQ; i < INVOKE_AT_PUT; i++) {
    Opcode opcode = static_cast<Opcode>(i);
    if (Symbol::for_invoke(opcode) == name) return opcode;
  }
  return INVOKE_VIRTUAL;
}

/// Transforms virtual calls into static calls (when possible).
/// Transforms virtual getters/setters into field accesses (when possible).
Expression* optimize_virtual_call(CallVirtual* node,
                                  Class* holder,
                                  Method* method,
                                  UnorderedSet<Symbol>& field_names,
                                  UnorderedMap<Class*, QueryableClass>& queryables) {
  auto dot = node->target();
  auto receiver = dot->receiver();

  Method* direct_method = null;
  Selector<CallShape> selector(node->target()->selector(), node->shape());
  Opcode opcode = opcode_for(selector);

  if (is_This(receiver, holder, method)) {
    auto queryable = queryables.at(holder);
    direct_method = queryable.lookup(selector);
  } else {
    Type guaranteed_type = compute_guaranteed_type(receiver, holder, method);
    if (guaranteed_type.is_valid()
        && !guaranteed_type.is_nullable()
        && guaranteed_type.klass()->is_instantiated()
        && !guaranteed_type.klass()->is_interface()) {
      auto queryable = queryables.at(guaranteed_type.klass());
      direct_method = queryable.lookup(selector);
    }

    if (direct_method != null && direct_method->is_abstract()) {
      direct_method = null;
    }

    // We need to be careful not to directly call an operator ==.
    // If the RHS is nullable, the interpreter shortcuts the call.
    if (direct_method != null && opcode == INVOKE_EQ) {
      auto param = node->arguments().first();
      Type param_type = compute_guaranteed_type(param, holder, method);
      if (param_type.is_valid()) {
        // Unless the param-type is nullable, we can change to a static call.
        if (param_type.is_nullable()) direct_method = null;
      } else if (param->is_Literal()) {
        // Unless the literal is `null`, we can change to a static call.
        if (param->is_LiteralNull()) direct_method = null;
      } else {
        // Not enough information, so abandon and assume we can't change to static call.
        direct_method = null;
      }
    }
    // Similarly, we don't want to change any of the really efficient INVOKE_X opcodes.
    if (direct_method != null && opcode != INVOKE_VIRTUAL) {
      // TODO(florian): we may switch to a static call if the receiver isn't an int/Array.
      direct_method = null;
    }
  }

  // TODO(kasper): This feels a bit hacky, but we prefer keeping the virtual
  // calls non-direct for the purposes of the type propagation phase.
  if (Flags::propagate) {
    direct_method = null;
  }

  if (direct_method == null) {
    // Can' make it a direct call, but maybe it's a potential field access.
    bool is_potential_field = field_names.contains(selector.name());
    if (is_potential_field && node->shape() == CallShape::for_instance_getter()) {
      node->set_opcode(INVOKE_VIRTUAL_GET);
    } else if (is_potential_field && node->shape() == CallShape::for_instance_setter()) {
      node->set_opcode(INVOKE_VIRTUAL_SET);
    } else {
      // Maybe it's an arithmetic/conditional operation.
      node->set_opcode(opcode);
    }
    return node;
  }

  if (direct_method->is_FieldStub()) {
    auto field_stub = direct_method->as_FieldStub();
    auto field = field_stub->field();
    bool is_getter = field_stub->is_getter();
    if (is_getter) return _new FieldLoad(receiver, field, node->range());
    // If the field is final don't inline the stub, but still transform it
    // into a static call by falling through.
    if (!field->is_final()) {
      Expression* value = node->arguments()[0];
      if (field_stub->checked_type().is_valid()) {
        // TODO: optimize the typecheck. We might not actually need it.
        value = _new Typecheck(Typecheck::FIELD_AS_CHECK,
                               value,
                               field_stub->checked_type(),
                               field_stub->checked_type().klass()->name(),
                               node->range());
        value = optimize_typecheck(value->as_Typecheck(),
                                   holder,
                                   method);
      }
      return _new FieldStore(receiver, field, value, node->range());
    }
  }
  ListBuilder<Expression*> new_arguments;
  new_arguments.add(receiver);
  new_arguments.add(node->arguments());
  auto result = _new CallStatic(_new ReferenceMethod(direct_method, node->range()),
                                new_arguments.build(),
                                node->shape(),
                                node->range());
  return result;
}

} // namespace toit::compiler
} // namespace toit
