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

#include "../../top.h"
#include "../../objects.h"

#include <vector>
#include <unordered_map>

namespace toit {

class Program;

namespace compiler {

class MethodTemplate;

class TypeSet {
 public:
  TypeSet(const TypeSet& other)
      : bits_(other.bits_) {}

  bool contains(unsigned id) const {
    uword old_bits = bits_[id / WORD_BIT_SIZE];
    uword mask = 1 << (id % WORD_BIT_SIZE);
    return (old_bits & mask) != 0;
  }

  bool add(unsigned id) {
    unsigned index = id / WORD_BIT_SIZE;
    uword old_bits = bits_[index];
    uword mask = 1 << (id % WORD_BIT_SIZE);
    bits_[index] = old_bits | mask;
    return (old_bits & mask) != 0;
  }

  bool add_all(TypeSet* other, int words) {
    bool added = false;
    for (int i = 0; i < words; i++) {
      uword old_bits = bits_[i];
      uword new_bits = old_bits | other->bits_[i];
      added = added || (new_bits != old_bits);
      bits_[i] = new_bits;
    }
    return added;
  }

  void clear(int words) {
    memset(bits_, 0, words * WORD_SIZE);
  }

  void fill(int words) {
    memset(bits_, 0xff, words * WORD_SIZE);
  }

  void print(Program* program, const char* banner);

 private:
  explicit TypeSet(uword* bits)
      : bits_(bits) {}

  uword* const bits_;

  friend class TypeStack;
  friend class TypeResult;
};

class TypeResult {
 public:
  explicit TypeResult(int words_per_type)
      : words_per_type_(words_per_type)
      , bits_(static_cast<uword*>(malloc(words_per_type * WORD_SIZE)))
      , type_(bits_) {}

  ~TypeResult() {
    free(bits_);
  }

  TypeSet type() const {
    return type_;
  }

  bool merge(TypeSet* other);

 private:
  const int words_per_type_;
  uword* const bits_;
  TypeSet type_;
};

class TypeStack {
 public:
  TypeStack(int sp, int size, int words_per_type)
      : sp_(sp)
      , size_(size)
      , words_per_type_(words_per_type)
      , words_(static_cast<uword*>(malloc(size * words_per_type_ * WORD_SIZE))) {}

  ~TypeStack() {
    free(words_);
  }

  TypeSet get(unsigned index) {
    return TypeSet(&words_[index * words_per_type_]);
  }

  void set(unsigned index, TypeSet type) {
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
    return top.add_all(&type, words_per_type_);
  }

  TypeSet push_empty();

  void push_any();
  void push_null(Program* program);
  void push_smi(Program* program);
  void push_instance(int id);
  void push(Program* program, Object* object);

  void pop() {
    sp_--;
  }

  bool merge(TypeStack* other);

  // TODO(kasper): Poor name.
  void seed_arguments(std::vector<int> arguments);

  TypeStack* copy() {
    return new TypeStack(this);
  }

 private:
  int sp_;
  const int size_;
  const int words_per_type_;
  uword* const words_;

  explicit TypeStack(TypeStack* other)
      : sp_(other->sp_)
      , size_(other->size_)
      , words_per_type_(other->words_per_type_)
      , words_(static_cast<uword*>(malloc(size_ * words_per_type_ * WORD_SIZE))) {
    memcpy(words_, other->words_, (sp_ + 1) * words_per_type_ * WORD_SIZE);
  }
};

class TypePropagator {
 public:
  explicit TypePropagator(Program* program);

  Program* program() const { return program_; }
  int words_per_type() const;
  void propagate();

  void call_static(TypeStack* stack, uint8* caller, Method target);
  void call_virtual(TypeStack* stack, uint8* caller, int arity, int offset);

 private:
  Program* const program_;
  std::unordered_map<uint8*, std::vector<MethodTemplate*>> templates_;

  void call_method(TypeStack* stack, uint8* caller, Method target, std::vector<int>& arguments);

  MethodTemplate* find(uint8* caller, Method target, std::vector<int> arguments);
  MethodTemplate* instantiate(Method method, std::vector<int> arguments);
};

class MethodTemplate {
 public:
  MethodTemplate(TypePropagator* propagator, Method method, std::vector<int> arguments)
      : propagator_(propagator)
      , method_(method)
      , arguments_(arguments)
      , result_(propagator->words_per_type()) {}

  TypePropagator* propagator() const { return propagator_; }

  bool matches(Method target, std::vector<int> arguments) {
    if (target.entry() != method_.entry()) return false;
    for (unsigned i = 0; i < arguments.size(); i++) {
      if (arguments[i] != arguments_[i]) return false;
    }
    return true;
  }

  TypeSet type() {
    return result_.type();
  }

  TypeSet call() {
    // TODO(kasper): Register dependency.
    return type();
  }

  void ret(TypeStack* stack) {
    TypeSet top = stack->local(0);
    result_.merge(&top);
    stack->pop();
  }

  void propagate();

 private:
  TypePropagator* const propagator_;
  const Method method_;
  const std::vector<int> arguments_;
  TypeResult result_;
};

} // namespace toit::compiler
} // namespace toit
