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

class TypePropagator {
 public:
  explicit TypePropagator(Program* program);

  Program* program() const { return program_; }
  int words_per_type() const { return words_per_type_; }

  void propagate(TypeDatabase* types);

  void call_static(MethodTemplate* caller, TypeScope* scope, uint8* site, Method target);
  void call_virtual(MethodTemplate* caller, TypeScope* scope, uint8* site, int arity, int offset);

  void propagate_through_lambda(Method method);

  void load_field(MethodTemplate* user, TypeStack* stack, uint8* site, int index);
  void store_field(MethodTemplate* user, TypeStack* stack, int index);

  void load_outer(TypeScope* stack, uint8* site, int index);

  TypeVariable* global_variable(int index);
  TypeVariable* field(unsigned type, int index);
  TypeVariable* outer(uint8* site);

  void enqueue(MethodTemplate* method);
  void add_site(uint8* site, TypeVariable* result);

#define ENSURE_ENTRY_POINT(name, symbol, arity) \
  void ensure_##name();
  ENTRY_POINTS(ENSURE_ENTRY_POINT)
#undef ENSURE_ENTRY_POINT

 private:
  Program* const program_;
  int words_per_type_;

#define HAS_ENTRY_POINT(name, symbol, arity) \
  bool has_##name##_ = false;
  ENTRY_POINTS(HAS_ENTRY_POINT)
#undef HAS_ENTRY_POINT

  Map<uint8*, Set<TypeVariable*>> sites_;

  std::unordered_map<uint8*, std::vector<MethodTemplate*>> templates_;
  std::unordered_map<int, TypeVariable*> globals_;
  std::unordered_map<uint8*, TypeVariable*> outers_;
  std::unordered_map<unsigned, std::unordered_map<int, TypeVariable*>> fields_;
  std::vector<MethodTemplate*> enqueued_;

  void call_method(MethodTemplate* caller, TypeScope* scope, uint8* site, Method target, std::vector<ConcreteType>& arguments);

  MethodTemplate* find(Method target, std::vector<ConcreteType> arguments);
  MethodTemplate* instantiate(Method method, std::vector<ConcreteType> arguments);
};

class MethodTemplate {
 public:
  MethodTemplate(TypePropagator* propagator, Method method, std::vector<ConcreteType> arguments)
      : propagator_(propagator)
      , method_(method)
      , arguments_(arguments)
      , result_(propagator->words_per_type()) {}

  TypePropagator* propagator() const { return propagator_; }

  int arity() const { return arguments_.size(); }
  ConcreteType argument(int index) { return arguments_[index]; }
  Method method() const { return method_; }
  int method_id() const;

  bool matches(Method target, std::vector<ConcreteType> arguments) {
    if (target.entry() != method_.entry()) return false;
    for (unsigned i = 0; i < arguments.size(); i++) {
      if (!arguments[i].matches(arguments_[i])) return false;
    }
    return true;
  }

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

  BlockTemplate* find_block(Method method, int level, uint8* site);
  void collect_blocks(std::unordered_map<uint8*, std::vector<BlockTemplate*>>& map);

  void propagate();

 private:
  TypePropagator* const propagator_;
  const Method method_;
  const std::vector<ConcreteType> arguments_;
  TypeVariable result_;
  bool enqueued_ = false;

  std::unordered_map<uint8*, BlockTemplate*> blocks_;
};

class BlockTemplate {
 public:
  BlockTemplate(MethodTemplate* origin, Method method, int level, int words_per_type)
      : origin_(origin)
      , method_(method)
      , level_(level)
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
  }

  MethodTemplate* origin() const { return origin_; }
  Method method() const { return method_; }
  int method_id(Program* program) const;
  int level() const { return level_; }
  int arity() const { return method_.arity(); }
  TypeVariable* argument(int index) { return arguments_[index]; }
  bool is_invoked_from_try_block() const { return is_invoked_from_try_block_; }

  ConcreteType pass_as_argument(TypeScope* scope) {
    // If we pass a block as an argument inside a try-block, we
    // conservatively assume that it is going to be invoked.
    if (scope->is_in_try_block()) invoke_from_try_block();
    return ConcreteType(this);
  }

  TypeSet invoke(TypePropagator* propagator, TypeScope* scope, uint8* site) {
    if (scope->is_in_try_block()) invoke_from_try_block();
    return result_.use(propagator, scope->method(), site);
  }

  void ret(TypePropagator* propagator, TypeStack* stack) {
    TypeSet top = stack->local(0);
    result_.merge(propagator, top);
    stack->pop();
  }

  void propagate(TypeScope* scope, std::vector<Worklist*>& worklists, bool linked);

 private:
  MethodTemplate* const origin_;
  const Method method_;
  const int level_;
  TypeVariable** const arguments_;
  TypeVariable result_;
  bool is_invoked_from_try_block_ = false;

  void invoke_from_try_block();
};

} // namespace toit::compiler
} // namespace toit
