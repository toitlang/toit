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

#include "type_set.h"

#include "../map.h"
#include "../set.h"

#include "../../top.h"
#include "../../objects.h"

#include <vector>
#include <unordered_map>

namespace toit {

class Program;

namespace compiler {

class TypePropagator;
class MethodTemplate;
class BlockTemplate;

class ConcreteType {
 public:
  explicit ConcreteType()
      : data_(ANY) {}

  explicit ConcreteType(unsigned id)
      : data_((id << 1) | 1) {}

  explicit ConcreteType(BlockTemplate* block)
      : data_(reinterpret_cast<uword>(block)) {}

  bool is_block() const {
    return (data_ & 1) == 0;
  }

  bool is_any() const {
    return data_ == ANY;
  }

  bool matches(const ConcreteType& other) const {
    return data_ == other.data_;
  }

  unsigned id() const {
    ASSERT(!is_block());
    return data_ >> 1;
  }

  BlockTemplate* block() const {
    ASSERT(is_block());
    return reinterpret_cast<BlockTemplate*>(data_);
  }

 private:
  static const uword ANY = ~0UL;
  uword data_;
};

class TypeResult {
 public:
  explicit TypeResult(int words_per_type)
      : words_per_type_(words_per_type)
      , bits_(static_cast<uword*>(malloc(words_per_type * WORD_SIZE)))
      , type_(bits_) {
    memset(bits_, 0, words_per_type * WORD_SIZE);
  }

  ~TypeResult() {
    free(bits_);
  }

  TypeSet type() const {
    return type_;
  }

  TypeSet use(TypePropagator* propagator, MethodTemplate* user, uint8* site);
  bool merge(TypePropagator* propagator, TypeSet other);

 private:
  const int words_per_type_;
  uword* const bits_;
  TypeSet type_;

  Set<MethodTemplate*> users_;
};

class TypeStack {
 public:
  TypeStack(int sp, int size, int words_per_type)
      : sp_(sp)
      , size_(size)
      , words_per_type_(words_per_type)
      , words_(static_cast<uword*>(malloc(size * words_per_type_ * WORD_SIZE))) {
    memset(words_, 0, (sp + 1) * words_per_type * WORD_SIZE);
  }

  ~TypeStack() {
    free(words_);
  }

  int sp() const {
    return sp_;
  }

  TypeStack* outer() const {
    return outer_;
  }

  void set_outer(TypeStack* outer) {
    outer_ = outer;
  }

  int level() const {
    if (!outer_) return 0;
    return outer_->level() + 1;
  }

  TypeSet get(unsigned index) {
    ASSERT(index >= 0);
    ASSERT(index < size_);
    return TypeSet(&words_[index * words_per_type_]);
  }

  void set(unsigned index, TypeSet type) {
    ASSERT(index >= 0);
    ASSERT(index < size_);
    memcpy(&words_[index * words_per_type_], type.bits_, words_per_type_ * WORD_SIZE);
  }

  TypeSet local(unsigned index) {
    return get(sp_ - index);
  }

  void set_local(unsigned index, TypeSet type) {
    set(sp_ - index, type);
  }

  void drop_arguments(unsigned arity) {
    if (arity == 0) return;
    TypeSet top = local(0);
    set_local(arity, top);
    sp_ -= arity;
  }

  void push(TypeSet type) {
    sp_++;
    set_local(0, type);
  }

  bool merge_top(TypeSet type) {
    TypeSet top = local(0);
    return top.add_all(type, words_per_type_);
  }

  TypeSet push_empty();

  void push_any();
  void push_null(Program* program);
  void push_bool(Program* program);
  void push_smi(Program* program);
  void push_int(Program* program);
  void push_float(Program* program);
  void push_string(Program* program);
  void push_array(Program* program);
  void push_byte_array(Program* program, bool nullable=false);
  void push_instance(unsigned id);
  void push(Program* program, Object* object);
  void push_block(BlockTemplate* block);

  void pop() {
    sp_--;
  }

  bool merge(TypeStack* other);

  // TODO(kasper): Poor name.
  void seed_arguments(std::vector<ConcreteType> arguments);

  TypeStack* copy() {
    return new TypeStack(this);
  }

 private:
  int sp_;
  const int size_;
  const int words_per_type_;
  uword* const words_;
  TypeStack* outer_ = null;

  explicit TypeStack(TypeStack* other)
      : sp_(other->sp_)
      , size_(other->size_)
      , words_per_type_(other->words_per_type_)
      , words_(static_cast<uword*>(malloc(size_ * words_per_type_ * WORD_SIZE)))
      , outer_(other->outer_) {
    memcpy(words_, other->words_, (sp_ + 1) * words_per_type_ * WORD_SIZE);
  }
};

class TypePropagator {
 public:
  explicit TypePropagator(Program* program);

  Program* program() const { return program_; }
  int words_per_type() const { return words_per_type_; }
  void propagate();

  void call_static(MethodTemplate* caller, TypeStack* stack, uint8* site, Method target);
  void call_virtual(MethodTemplate* caller, TypeStack* stack, uint8* site, int arity, int offset);

  void load_field(MethodTemplate* user, TypeStack* stack, uint8* site, int index);
  void store_field(MethodTemplate* user, TypeStack* stack, int index);

  void load_outer(TypeStack* stack, uint8* site, int index);

  TypeResult* global_variable(int index);
  TypeResult* field(unsigned type, int index);
  TypeResult* outer(uint8* site);

  void enqueue(MethodTemplate* method);
  void add_site(uint8* site, TypeResult* result);

 private:
  Program* const program_;
  int words_per_type_;

  Map<uint8*, Set<TypeResult*>> sites_;

  std::unordered_map<uint8*, std::vector<MethodTemplate*>> templates_;
  std::unordered_map<int, TypeResult*> globals_;
  std::unordered_map<uint8*, TypeResult*> outers_;
  std::unordered_map<unsigned, std::unordered_map<int, TypeResult*>> fields_;
  std::vector<MethodTemplate*> enqueued_;

  void call_method(MethodTemplate* caller, TypeStack* stack, uint8* site, Method target, std::vector<ConcreteType>& arguments);

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
  TypeResult result_;
  bool enqueued_ = false;

  std::unordered_map<uint8*, BlockTemplate*> blocks_;
};

class BlockTemplate {
 public:
  BlockTemplate(Method method, int level, int words_per_type)
      : method_(method)
      , level_(level)
      , arguments_(static_cast<TypeResult**>(malloc(method.arity() * sizeof(TypeResult*))))
      , result_(words_per_type) {
    // TODO(kasper): It is silly that we keep the receiver in here.
    for (int i = 0; i < method_.arity(); i++) {
      arguments_[i] = new TypeResult(words_per_type);
    }
  }

  ~BlockTemplate() {
    for (int i = 0; i < method_.arity(); i++) {
      delete arguments_[i];
    }
    free(arguments_);
  }

  int method_id(Program* program) const;

  int level() const {
    return level_;
  }

  int arity() const {
    return method_.arity();
  }

  TypeResult* argument(int index) {
    return arguments_[index];
  }

  TypeSet use(TypePropagator* propagator, MethodTemplate* user, uint8* site) {
    return result_.use(propagator, user, site);
  }

  void ret(TypePropagator* propagator, TypeStack* stack) {
    TypeSet top = stack->local(0);
    result_.merge(propagator, top);
    stack->pop();
  }

  void propagate(MethodTemplate* context, TypeStack* outer);

 private:
  const Method method_;
  const int level_;
  TypeResult** const arguments_;
  TypeResult result_;
};

} // namespace toit::compiler
} // namespace toit
