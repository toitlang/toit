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
#include "concrete_type.h"

#include "../../top.h"
#include "../../objects.h"

#include <vector>

namespace toit {

class Program;

namespace compiler {

class TypeStack {
 public:
  TypeStack(int sp, int size, int words_per_type)
      : sp_(sp)
      , size_(size)
      , words_per_type_(words_per_type)
      , words_(static_cast<uword*>(malloc(size * words_per_type * WORD_SIZE))) {
    memset(words_, 0, (sp + 1) * words_per_type * WORD_SIZE);
  }

  ~TypeStack() {
    free(words_);
  }

  int sp() const {
    return sp_;
  }

  TypeSet get(int index) {
    ASSERT(index >= 0);
    ASSERT(index <= sp_);
    ASSERT(index < size_);
    return TypeSet(&words_[index * words_per_type_]);
  }

  void set(int index, TypeSet type) {
    ASSERT(index >= 0);
    ASSERT(index <= sp_);
    ASSERT(index < size_);
    memcpy(&words_[index * words_per_type_], type.bits_, words_per_type_ * WORD_SIZE);
  }

  TypeSet local(int index) {
    return get(sp_ - index);
  }

  void set_local(int index, TypeSet type) {
    set(sp_ - index, type);
  }

  void drop_arguments(int arity) {
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
  void push_bool_specific(Program* program, bool value);
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

} // namespace toit::compiler
} // namespace toit
