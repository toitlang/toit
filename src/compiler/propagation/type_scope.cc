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
    , stacks_(static_cast<TypeStack**>(malloc(1 * sizeof(TypeStack*))))
    , level_(0)
    , outer_(null) {
  int sp = method->method().arity() + Interpreter::FRAME_SIZE;
  TypeStack* stack = new TypeStack(sp - 1, sp + method->method().max_height() + 1, words_per_type_);
  stacks_[0] = stack;

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
    , stacks_(static_cast<TypeStack**>(malloc((outer->level() + 2) * sizeof(TypeStack*))))
    , level_(outer->level() + 1)
    , outer_(outer) {
  for (int i = 0; i <= outer->level(); i++) {
    stacks_[i] = outer->stacks_[i]->copy();
  }

  Method method = block->method();
  int sp = method.arity() + Interpreter::FRAME_SIZE;
  TypeStack* stack = new TypeStack(sp - 1, sp + method.max_height() + 1, words_per_type_);
  stacks_[level_] = stack;

  TypeSet receiver = stack->get(0);
  receiver.set_block(block);
  for (int i = 1; i < method.arity(); i++) {
    TypeSet type = block->argument(i)->type();
    stack->set(i, type);
  }
}

TypeScope::TypeScope(const TypeScope* other)
    : words_per_type_(other->words_per_type_)
    , stacks_(static_cast<TypeStack**>(malloc((other->level() + 1) * sizeof(TypeStack*))))
    , level_(other->level())
    , outer_(other->outer_) {
  for (int i = 0; i <= other->level(); i++) {
    stacks_[i] = other->stacks_[i]->copy();
  }
}

TypeScope::~TypeScope() {
  for (int i = 0; i <= level_; i++) {
    delete stacks_[i];
  }
  free(stacks_);
}

TypeSet TypeScope::load_outer(TypeSet block, int index) {
  TypeStack* stack = stacks_[block.block()->level()];
  return stack->local(index);
}

void TypeScope::store_outer(TypeSet block, int index, TypeSet value) {
  TypeStack* stack = stacks_[block.block()->level()];
  stack->set_local(index, value);
}

TypeScope* TypeScope::copy() const {
  return new TypeScope(this);
}

bool TypeScope::merge(const TypeScope* other) {
  ASSERT(level_ <= other->level());
  bool result = false;
  for (int i = 0; i <= level_; i++) {
    result = stacks_[i]->merge(other->stacks_[i]) || result;
  }
  return result;
}

} // namespace toit::compiler
} // namespace toit
