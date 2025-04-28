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

  if (selector.name() == Symbols::size &&
      selector.shape() == CallShape(0).with_implicit_this()) {
    return INVOKE_SIZE;
  }

  // If this isn't a binary, non-setter method, we just treat it as
  // an ordinary virtual invocation.
  if (selector.shape() != CallShape(1).with_implicit_this()) return INVOKE_VIRTUAL;

  auto name = selector.name();
  ASSERT(INVOKE_SIZE > INVOKE_AT_PUT);
  for (int i = INVOKE_EQ; i < INVOKE_AT_PUT; i++) {
    Opcode opcode = static_cast<Opcode>(i);
    if (Symbol::for_invoke(opcode) == name) return opcode;
  }
  return INVOKE_VIRTUAL;
}

/// Transforms virtual calls into static calls (when possible).
/// Transforms virtual getters/setters into field accesses (when possible).
/// The 'direct_queryables' map only contains methods that are known to be "good"
///   if a receiver has the given type. That is, methods that are overwritten have
///   been removed from it.
Expression* optimize_virtual_call(CallVirtual* node,
                                  Class* holder,
                                  Method* method,
                                  List<Type> literal_types,
                                  UnorderedSet<Symbol>& field_names,
                                  UnorderedMap<Class*, QueryableClass>& direct_queryables) {
  auto dot = node->target();
  auto receiver = dot->receiver();

  Method* direct_method = null;
  Selector<CallShape> selector(node->target()->selector(), node->shape());
  Opcode opcode = opcode_for(selector);

  if (is_This(receiver, holder, method)) {
    // For simplicity, don't optimize mixins. There are some cases where we could
    // change a virtual call to a static one, but it requires more work.
    if (holder->is_mixin()) return node;

    auto queryable = direct_queryables.at(holder);
    direct_method = queryable.lookup(selector);
  } else {
    Type guaranteed_type = compute_guaranteed_type(receiver, holder, method, literal_types);
    if (guaranteed_type.is_valid()
        && !guaranteed_type.is_nullable()
        && !guaranteed_type.klass()->is_interface()
        // For simplicity, don't optimize mixins. There are some cases where we could
        // change a virtual call to a static one, but it requires more work.
        && !guaranteed_type.klass()->is_mixin()) {
      auto queryable = direct_queryables.at(guaranteed_type.klass());
      direct_method = queryable.lookup(selector);
    }

    if (direct_method != null && direct_method->is_abstract()) {
      direct_method = null;
    }
  }

  if (direct_method == null) {
    // Can' make it a direct call, but maybe it's a potential field access.
    bool is_potential_field = field_names.contains(selector.name());
    if (is_potential_field &&
        node->shape() == CallShape::for_instance_getter() &&
        opcode != INVOKE_SIZE) {
      node->set_opcode(INVOKE_VIRTUAL_GET);
    } else if (is_potential_field && node->shape() == CallShape::for_instance_setter()) {
      node->set_opcode(INVOKE_VIRTUAL_SET);
    } else {
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
        value = _new Typecheck(Typecheck::FIELD_AS_CHECK,
                               value,
                               field_stub->checked_type(),
                               field_stub->checked_type().klass()->name(),
                               node->range());
        value = optimize_typecheck(value->as_Typecheck(),
                                   holder,
                                   method,
                                   literal_types);
      }
      return _new FieldStore(receiver, field, value, node->range());
    }
  }

  if (opcode != INVOKE_VIRTUAL) {
    // We don't want to change any of the really efficient INVOKE_X opcodes even if
    // we know the target. These bytecodes are optimized for numbers/arrays and shortcut
    // lots of bytecodes.
    // TODO(florian): change to a static call when the receiver isn't one of
    //    the optimized types. In that case make sure to special case
    //    `INVOKE_EQ`: the virtual machine does a null-check on the RHS before
    //    calling the virtual method.
    //    See https://github.com/toitlang/toit/blob/e4f55512efd2880c5ab68960ae4c0a21a69ab349/src/compiler/optimizations/virtual_call.cc#L82
    //    for how to treat the `INVOKE_EQ`.
    direct_method = null;
    node->set_opcode(opcode);
    return node;
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
