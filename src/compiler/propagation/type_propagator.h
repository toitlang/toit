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

#pragma once

#include "concrete_type.h"
#include "type_set.h"
#include "type_stack.h"
#include "type_variable.h"
#include "type_scope.h"
#include "worklist.h"

#include "../map.h"
#include "../method_selector_offsets.h"
#include "../set.h"

#include "../../top.h"
#include "../../objects.h"
#include "../../entry_points.h"

#include <vector>
#include <unordered_map>

namespace toit {

class Program;

namespace compiler {

class MethodTemplate;
class BlockTemplate;
class TypeDatabase;

// Where a non-local branch or return is headed while it is unwinding.
// It corresponds to the information the interpreter stores in the link
// information on the stack before running the finally code.
struct UnwindTarget {
  // Non-local return from the block or method at the level of the block.
  explicit UnwindTarget(BlockTemplate* block)
      : block(block), bcp(null), height_diff(0) {}
  // Non-local branch to the given bcp at the level of the block.
  UnwindTarget(BlockTemplate* block, uint8* bcp, int height_diff)
      : block(block), bcp(bcp), height_diff(height_diff) {}

  bool operator==(const UnwindTarget& other) const {
    return block == other.block && bcp == other.bcp && height_diff == other.height_diff;
  }

  BlockTemplate* block;
  uint8* bcp;
  int height_diff;
};

// The finally code of a try-block that runs on the way to a target.
struct Unwinding {
  Unwinding(const UnwindTarget& target, BlockTemplate* try_block)
      : target(target), try_block(try_block) {}

  const UnwindTarget target;
  BlockTemplate* const try_block;
};

class TypePropagator {
 public:
  TypePropagator(
      Program* program,
      const MethodSelectorOffsets* method_selector_offsets = null);
  ~TypePropagator();

  Program* program() const { return program_; }
  int words_per_type() const { return words_per_type_; }
  word selector_offset(Method method) const;

  void propagate(TypeDatabase* types);

  void call_static(MethodTemplate* caller, TypeScope* scope, uint8* site, Method target, std::vector<Worklist*>& worklists);
  void call_virtual(MethodTemplate* caller, TypeScope* scope, uint8* site, int arity, word offset, std::vector<Worklist*>& worklists);
  void call_block(TypeScope* scope, uint8* site, int arity, bool linked, bool own, std::vector<Worklist*>& worklists);

  // Continue a non-local branch or return from the given scope. It
  // either reaches the target or stops at the innermost try-block.
  void unwind(TypeScope* scope, const UnwindTarget& target, std::vector<Worklist*>& worklists);

  void load_block(MethodTemplate* loader, TypeScope* scope, Method method);
  void load_lambda(TypeScope* scope, Method method);

  void load_field(MethodTemplate* user, TypeStack* stack, uint8* site, int index);
  void store_field(MethodTemplate* user, TypeStack* stack, int index);

  void load_outer(TypeScope* stack, uint8* site, int index);
  bool handle_typecheck_result(TypeScope* stack, uint8* site, bool as_check, int result);

  TypeVariable* global_variable(int index);
  TypeVariable* field(unsigned type, int index);
  TypeVariable* output(uint8* site);

  void enqueue(MethodTemplate* method);

  // Instances of a class can only be used if they have been allocated. The
  // analysis sees classes that are never allocated because the 'any' type and
  // the type checks on it include all classes, but there are no instances for
  // the methods on them to work on. If the instances show up later, we go
  // back to the callers that have asked.
  bool has_instances(unsigned type, MethodTemplate* caller);
  void mark_allocated(unsigned type);

  void add_input(uint8* site, TypeStack* input, int n);
  void add_output(uint8* site, TypeVariable* output);

#define ENSURE_ENTRY_POINT(name, symbol, arity) \
  void ensure_##name();
  ENTRY_POINTS(ENSURE_ENTRY_POINT)
#undef ENSURE_ENTRY_POINT

 private:
  Program* const program_;
  const MethodSelectorOffsets* method_selector_offsets_;

  std::vector<bool> allocated_;
  std::vector<std::vector<MethodTemplate*>> waiting_for_allocation_;
  std::vector<unsigned> newly_allocated_;

  void initialize_allocated();
  bool enqueue_waiting_for_allocation();
  void mark_allocated(Object* object);
  int words_per_type_;

#define HAS_ENTRY_POINT(name, symbol, arity) \
  bool has_##name##_ = false;
  ENTRY_POINTS(HAS_ENTRY_POINT)
#undef HAS_ENTRY_POINT

  Map<uint8*, std::vector<TypeVariable*>> input_;
  Map<uint8*, Set<TypeVariable*>> output_;

  std::unordered_map<uint32, MethodTemplate*> methods_;
  std::unordered_map<uint32, BlockTemplate*> blocks_;

  std::unordered_map<int, TypeVariable*> globals_;
  std::unordered_map<uint8*, TypeVariable*> outers_;  // TODO(kasper): Rename this.
  std::unordered_map<unsigned, std::unordered_map<int, TypeVariable*>> fields_;
  std::vector<MethodTemplate*> enqueued_;

  void call_method(MethodTemplate* caller,
                   TypeScope* scope,
                   uint8* site,
                   Method target,
                   std::vector<ConcreteType>& arguments);

  void propagate_blocks(MethodTemplate* caller,
                       TypeScope* scope,
                       int arity,
                       std::vector<Worklist*>& worklists);

  MethodTemplate* find_method(Method target, const std::vector<ConcreteType>& arguments);
  BlockTemplate* find_block(MethodTemplate* origin, Method method, int level, int sp);
};

class MethodTemplate {
 public:
  MethodTemplate(MethodTemplate* next, TypePropagator* propagator, Method method, const std::vector<ConcreteType>& arguments)
      : next_(next)
      , propagator_(propagator)
      , method_(method)
      , arguments_(arguments)
      , result_(propagator->words_per_type()) {}

  ~MethodTemplate() {
    delete next_;
  }

  MethodTemplate* next() const { return next_; }
  TypePropagator* propagator() const { return propagator_; }
  const std::vector<ConcreteType>& arguments() const { return arguments_; }

  int arity() const { return arguments_.size(); }
  ConcreteType argument(int index) { return arguments_[index]; }
  Method method() const { return method_; }
  int method_id() const;

  bool matches(Method target, const std::vector<ConcreteType>& arguments) const;

  bool analyzed() const { return analyzed_; }
  bool enqueued() const { return enqueued_; }
  void mark_enqueued() { enqueued_ = true; }
  void clear_enqueued() { enqueued_ = false; }

  TypeSet call(TypePropagator* propagator, MethodTemplate* caller, uint8* site) {
    return result_.use(propagator, caller, site);
  }

  void ret(TypePropagator* propagator, TypeStack* stack) {
    TypeSet top = stack->local(0);
    result_.merge(propagator, top);
    stack->pop();
  }

  void collect_method(std::unordered_map<uint8*, std::vector<MethodTemplate*>>* map);

  void propagate();

 private:
  // Method templates that are associated with the same
  // hash code (see ConcreteType::hash) are linked together
  // to handle hash collisions.
  MethodTemplate* const next_;

  TypePropagator* const propagator_;
  const Method method_;
  const std::vector<ConcreteType> arguments_;
  TypeVariable result_;

  bool enqueued_ = false;
  bool analyzed_ = false;
};

class BlockTemplate {
 public:
  BlockTemplate(BlockTemplate* next, MethodTemplate* origin, Method method, int level, int sp, int words_per_type)
      : next_(next)
      , origin_(origin)
      , method_(method)
      , level_(level)
      , sp_(sp)
      , arguments_(static_cast<TypeVariable**>(malloc(method.arity() * sizeof(TypeVariable*))))
      , result_(words_per_type) {
    // TODO(kasper): It is silly that we keep the receiver in here.
    for (int i = 0; i < method_.arity(); i++) {
      arguments_[i] = new TypeVariable(words_per_type);
    }
  }

  ~BlockTemplate() {
    for (int i = 0; i < method_.arity(); i++) {
      delete arguments_[i];
    }
    free(arguments_);
    for (Unwinding* unwinding : unwindings_) delete unwinding;
    delete next_;
  }

  BlockTemplate* next() const { return next_; }
  MethodTemplate* origin() const { return origin_; }
  Method method() const { return method_; }
  int method_id(Program* program) const;
  int level() const { return level_; }
  int sp() const { return sp_; }
  int arity() const { return method_.arity(); }
  TypeVariable* argument(int index) { return arguments_[index]; }
  bool is_invoked_from_try_block() const { return is_invoked_from_try_block_; }
  bool is_invoked_from_finally() const { return is_invoked_from_finally_; }
  bool is_analyzing() const { return is_analyzing_; }

  bool matches(Method target, int level, MethodTemplate* user) const;
  void use(TypePropagator* propagator, MethodTemplate* user);

  TypeSet invoke(TypePropagator* propagator, TypeScope* scope, uint8* site);
  void mark_invoked_from_try_block();
  void mark_invoked_from_finally();

  void ret(TypePropagator* propagator, TypeStack* stack) {
    TypeSet top = stack->local(0);
    result_.merge(propagator, top);
    stack->pop();
  }

  const std::vector<UnwindTarget>& unwind_targets() const { return unwind_targets_; }
  void add_unwind_target(const UnwindTarget& target);

  // For blocks linked in as try-blocks: The finally code that
  // follows the try-block and the unwindings that pass through it.
  uint8* finally_bcp() const { return finally_bcp_; }
  void set_finally_bcp(uint8* bcp) { finally_bcp_ = bcp; }
  Unwinding* unwinding(const UnwindTarget& target);

  bool propagate(TypeScope* scope, std::vector<Worklist*>& worklists, bool linked);

  void collect_block(std::unordered_map<uint8*, std::vector<BlockTemplate*>>* map);

 private:
  // Block templates that are associated with the same
  // hash code (see ConcreteType::hash) are linked together
  // to handle hash collisions.
  BlockTemplate* const next_;

  MethodTemplate* const origin_;
  const Method method_;
  const int level_;
  const int sp_;
  TypeVariable** const arguments_;
  TypeVariable result_;

  bool is_invoked_ = false;
  bool is_invoked_from_try_block_ = false;
  bool is_invoked_from_finally_ = false;
  bool is_analyzing_ = false;

  // All users of this block are various invocations of the same method.
  // These are the surrounding methods that load the block.
  Set<MethodTemplate*> users_;

  // The non-local branches and returns that continue from the code
  // that follows this block when it is done, because they cannot be
  // analyzed separately. There are only ever a few of these.
  std::vector<UnwindTarget> unwind_targets_;

  uint8* finally_bcp_ = null;
  std::vector<Unwinding*> unwindings_;

  // TODO(kasper): We temporarily keep a pointer to one of the
  // users around. It doesn't matter which one, because we're only
  // using it to determine if a BlockTemplate can be reused by
  // another user in the BlockTemplate::matches function.
  MethodTemplate* last_user_ = null;
};

} // namespace toit::compiler
} // namespace toit
