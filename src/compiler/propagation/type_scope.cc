// Copyright (C) 2022 Toitware ApS.
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

#include "type_scope.h"
#include "type_propagator.h"

#include "../../interpreter.h"

namespace toit {
namespace compiler {

TypeScope::TypeScope(MethodTemplate* method)
    : words_per_type_(method->propagator()->words_per_type())
    , level_(0)
    , outer_(null)
    , wrapped_(static_cast<uword*>(malloc(1 * sizeof(uword)))) {
  int sp = method->method().arity() + Interpreter::FRAME_SIZE;
  TypeStack* stack = new TypeStack(sp - 1, sp + method->method().max_height() + 1, words_per_type_);
  wrapped_[0] = wrap(stack, true);

  for (unsigned i = 0; i < method->arity(); i++) {
    TypeSet type = stack->get(i);
    ConcreteType argument_type = method->argument(i);
    if (argument_type.is_block()) {
      type.set_block(argument_type.block());
    } else if (argument_type.is_any()) {
      type.fill(words_per_type_);
    } else {
      type.add(argument_type.id());
    }
  }
}

TypeScope::TypeScope(BlockTemplate* block, TypeScope* outer)
    : words_per_type_(outer->words_per_type_)
    , level_(outer->level() + 1)
    , outer_(outer)
    , wrapped_(static_cast<uword*>(malloc((level_ + 1) * sizeof(uword)))) {
  for (int i = 0; i < level_; i++) {
    TypeStack* stack = unwrap(outer->wrapped_[i]);
    wrapped_[i] = wrap(stack, false);
  }

  Method method = block->method();
  int sp = method.arity() + Interpreter::FRAME_SIZE;
  TypeStack* stack = new TypeStack(sp - 1, sp + method.max_height() + 1, words_per_type_);
  wrapped_[level_] = wrap(stack, true);

  TypeSet receiver = stack->get(0);
  receiver.set_block(block);
  for (int i = 1; i < method.arity(); i++) {
    TypeSet type = block->argument(i)->type();
    stack->set(i, type);
  }
}

TypeScope::TypeScope(const TypeScope* other, bool lazy)
    : words_per_type_(other->words_per_type_)
    , level_(other->level())
    , outer_(other->outer_)
    , wrapped_(static_cast<uword*>(malloc((level_ + 1) * sizeof(uword)))) {
  for (int i = 0; i < level_; i++) {
    TypeStack* stack = other->at(i);
    wrapped_[i] = lazy ? wrap(stack, false) : wrap(stack->copy(), true);
  }
  // Always copy the top-most stack frame. It is manipulated
  // all the time, so we might as well copy it eagerly.
  wrapped_[level_] = wrap(other->at(level_)->copy(), true);
}

TypeScope::~TypeScope() {
  for (int i = 0; i <= level_; i++) {
    uword wrapped = wrapped_[i];
    if (is_copied(wrapped)) delete unwrap(wrapped);
  }
  free(wrapped_);
}

TypeSet TypeScope::load_outer(TypeSet block, int index) {
  TypeStack* stack = at(block.block()->level());
  return stack->local(index);
}

void TypeScope::store_outer(TypeSet block, int index, TypeSet value) {
  int level = block.block()->level();
  uword wrapped = wrapped_[level];
  TypeStack* stack = unwrap(wrapped);
  if (!is_copied(wrapped)) {
    stack = stack->copy();
    wrapped_[level] = wrap(stack, true);
  }
  stack->set_local(index, value);
}

TypeScope* TypeScope::copy() const {
  return new TypeScope(this, false);
}

TypeScope* TypeScope::copy_lazily() const {
  return new TypeScope(this, true);
}

bool TypeScope::merge(const TypeScope* other) {
  ASSERT(level_ <= other->level());
  bool result = false;
  for (int i = 0; i <= level_; i++) {
    TypeStack* stack = at(i);
    TypeStack* addition = other->at(i);
    if (stack == addition) continue;
    result = stack->merge(addition) || result;
  }
  return result;
}

} // namespace toit::compiler
} // namespace toit
