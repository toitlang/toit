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
      type.add_any(method->propagator()->program());
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
    , method_(outer->method())
    , outer_(outer)
    , wrapped_(static_cast<uword*>(malloc((level_ + 1) * sizeof(uword)))) {
  for (int i = 0; i < level_; i++) {
    TypeStack* stack = unwrap(outer->wrapped_[i]);
    wrapped_[i] = wrap(stack, false);
  }

  finally_depth_ = outer->finally_depth_;
  if (block->is_invoked_from_finally()) enter_finally();

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

// This is the constructor used from TypeScope::copy_lazy(). If the
// target scope is non-null, we only keep the outermost levels and
// make the copied scope match the target.
TypeScope::TypeScope(const TypeScope* source, const TypeScope* target)
    : words_per_type_(target->words_per_type_)
    , level_(target->level())
    , level_linked_(target->level_linked())
    , method_(target->method())
    , outer_(target->outer())
    , wrapped_(static_cast<uword*>(malloc((level_ + 1) * sizeof(uword))))
    , unwinding_(target->unwinding())
    , finally_depth_(target->finally_depth_) {
  for (int i = 0; i <= level_; i++) {
    wrapped_[i] = wrap(source->at(i), false);
  }
}

TypeScope::~TypeScope() {
  for (int i = 0; i <= level_; i++) {
    uword wrapped = wrapped_[i];
    if (is_copied(wrapped)) delete unwrap(wrapped);
  }
  for (TypeStack* stack : replaced_) delete stack;
  free(wrapped_);
}

TypeSet TypeScope::load_outer(TypeSet block, int index) {
  TypeStack* stack = at(block.block()->level());
  int delta = stack->sp() - block.block()->sp();
  return stack->local(index + delta);
}

void TypeScope::store_outer(TypeSet block, int index, TypeSet value) {
  int level = block.block()->level();
  uword wrapped = wrapped_[level];
  TypeStack* stack = unwrap(wrapped);
  int delta = stack->sp() - block.block()->sp();
  if (!is_copied(wrapped)) {
    stack = stack->copy();
    wrapped_[level] = wrap(stack, true);
  }
  stack->set_local(index + delta, value);
}

void TypeScope::throw_maybe() {
  if (level() == 0) return;
  outer()->merge(this, TypeScope::MERGE_UNWIND);
}

TypeScope* TypeScope::copy_lazy(const TypeScope* target) const {
  if (!target) target = this;
  return new TypeScope(this, target);
}

void TypeScope::own_stacks() {
  for (int i = 0; i <= level_; i++) {
    uword wrapped = wrapped_[i];
    if (!is_copied(wrapped)) wrapped_[i] = wrap(unwrap(wrapped)->copy(), true);
  }
}

TypeStack* TypeScope::copy_top() {
  ASSERT(top_ == null);
  uword wrapped = wrapped_[level_];
  TypeStack* top = unwrap(wrapped);
  if (!is_copied(wrapped)) {
    top = top->copy();
    wrapped_[level_] = wrap(top, true);
  }
  top_ = top;
  return top;
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
    case MERGE_OUTER:
      level_target = level_;
      break;
  }
  ASSERT(level_target <= level_);
  bool result = false;
  for (int i = 0; i <= level_target; i++) {
    uword wrapped = wrapped_[i];
    TypeStack* stack = unwrap(wrapped);
    TypeStack* addition = other->at(i);
    if (stack == addition) continue;
    if (i == level_ && is_copied(wrapped)) {
      // We never share the top stack with others once it is in use.
      result = stack->merge(addition) || result;
    } else if (stack->merge_required(addition)) {
      // Other scopes may be using this stack. If we changed it, they
      // would see our types without being told that they have changed,
      // so we replace it and keep the old one alive for them.
      TypeStack* copy = stack->copy();
      if (is_copied(wrapped)) replaced_.push_back(stack);
      wrapped_[i] = wrap(copy, true);
      copy->merge(addition);
      result = true;
    }
  }
  return result;
}

} // namespace toit::compiler
} // namespace toit
