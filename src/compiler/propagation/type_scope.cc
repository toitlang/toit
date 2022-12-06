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

// We add an extra stack slot to all stacks in scopes to
// allow for a single temporary value to be pushed. This
// is often used as an accumulator or a temporary result.
static const int EXTRA = 1;

TypeScope::TypeScope(MethodTemplate* method)
    : words_per_type_(method->propagator()->words_per_type())
    , level_(0)
    , level_linked_(-1)
    , method_(method)
    , outer_(null)
    , wrapped_(static_cast<uword*>(malloc(1 * sizeof(uword)))) {
  int sp = method->method().arity() + Interpreter::FRAME_SIZE;
  int size = sp + method->method().max_height() + EXTRA;
  TypeStack* stack = new TypeStack(sp - 1, size, words_per_type_);
  wrapped_[0] = wrap(stack, true);

  for (int i = 0; i < method->arity(); i++) {
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

TypeScope::TypeScope(int slots, int words_per_type)
    : words_per_type_(words_per_type)
    , level_(0)
    , level_linked_(-1)
    , method_(null)
    , outer_(null)
    , wrapped_(static_cast<uword*>(malloc(1 * sizeof(uword)))) {
  TypeStack* stack = new TypeStack(-1, slots + EXTRA, words_per_type_);
  wrapped_[0] = wrap(stack, true);
}

TypeScope::TypeScope(BlockTemplate* block, TypeScope* outer, bool linked)
    : words_per_type_(outer->words_per_type_)
    , level_(outer->level() + 1)
    , level_linked_(linked ? outer->level() : outer->level_linked())
    , method_(block->origin())
    , outer_(outer)
    , wrapped_(static_cast<uword*>(malloc((level_ + 1) * sizeof(uword)))) {
  for (int i = 0; i < level_; i++) {
    TypeStack* stack = unwrap(outer->wrapped_[i]);
    wrapped_[i] = wrap(stack, false);
  }

  Method method = block->method();
  int sp = method.arity() + Interpreter::FRAME_SIZE;
  int size = sp + method.max_height() + EXTRA;
  TypeStack* stack = new TypeStack(sp - 1, size, words_per_type_);
  wrapped_[level_] = wrap(stack, true);

  TypeSet receiver = stack->get(0);
  receiver.set_block(block);
  for (int i = 1; i < method.arity(); i++) {
    TypeSet type = block->argument(i)->type();
    stack->set(i, type);
  }
}

TypeScope::TypeScope(const TypeScope* other, int level, bool lazy)
    : words_per_type_(other->words_per_type_)
    , level_(level)
    , level_linked_(other->level_linked())
    , method_(other->method())
    , outer_(other->outer())
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

void TypeScope::throw_maybe() {
  if (level() == 0) return;
  outer()->merge(this, TypeScope::MERGE_UNWIND);
}

TypeScope* TypeScope::copy() const {
  return new TypeScope(this, level_, false);
}

TypeScope* TypeScope::copy_lazily(int level) const {
  if (level < 0) level = level_;
  return new TypeScope(this, level, true);
}

bool TypeScope::merge(const TypeScope* other, MergeKind kind) {
  int level_target = -1;
  switch (kind) {
    case MERGE_LOCAL:
      level_target = other->level();
      break;
    case MERGE_RETURN:
      level_target = other->level() - 1;
      break;
    case MERGE_UNWIND:
      level_target = other->level_linked();
      break;
  }
  ASSERT(level_target <= level_);
  bool result = false;
  for (int i = 0; i <= level_target; i++) {
    TypeStack* stack = at(i);
    TypeStack* addition = other->at(i);
    if (stack == addition) continue;
    result = stack->merge(addition) || result;
  }
  return result;
}

} // namespace toit::compiler
} // namespace toit
