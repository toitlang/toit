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

#include "type_stack.h"

namespace toit {
namespace compiler {

bool TypeStack::merge(TypeStack* other) {
  ASSERT(sp() == other->sp());
  bool result = false;
  for (int i = 0; i <= sp_; i++) {
    TypeSet existing_type = get(i);
    TypeSet other_type = other->get(i);
    if (existing_type.is_block()) {
      ASSERT(existing_type.block() == other_type.block());
    } else {
      result = existing_type.add_all(other_type, words_per_type_) || result;
    }
  }
  return result;
}

bool TypeStack::merge_required(TypeStack* other) {
  ASSERT(sp() == other->sp());
  for (int i = 0; i <= sp_; i++) {
    TypeSet existing_type = get(i);
    TypeSet other_type = other->get(i);
    if (existing_type.is_block()) {
      ASSERT(existing_type.block() == other_type.block());
    } else if (!existing_type.contains_all(other_type, words_per_type_)) {
      return true;
    }
  }
  return false;
}

TypeSet TypeStack::push_empty() {
  TypeSet result = get(++sp_);
  result.clear(words_per_type_);
  return result;
}

void TypeStack::push_any(Program* program) {
  TypeSet type = push_empty();
  type.add_any(program);
}

void TypeStack::push_null(Program* program) {
  TypeSet type = push_empty();
  type.add(program->null_class_id()->value());
}

void TypeStack::push_smi(Program* program) {
  TypeSet type = push_empty();
  type.add(program->smi_class_id()->value());
}

void TypeStack::push_int(Program* program) {
  TypeSet type = push_empty();
  type.add(program->smi_class_id()->value());
  type.add(program->large_integer_class_id()->value());
}

void TypeStack::push_float(Program* program) {
  TypeSet type = push_empty();
  type.add(program->double_class_id()->value());
}

void TypeStack::push_string(Program* program) {
  TypeSet type = push_empty();
  type.add(program->string_class_id()->value());
}

void TypeStack::push_array(Program* program) {
  TypeSet type = push_empty();
  type.add(program->array_class_id()->value());
}

void TypeStack::push_byte_array(Program* program, bool nullable) {
  TypeSet type = push_empty();
  type.add(program->byte_array_class_id()->value());
  if (nullable) type.add(program->null_class_id()->value());
}

void TypeStack::push_bool(Program* program) {
  TypeSet type = push_empty();
  type.add(program->true_class_id()->value());
  type.add(program->false_class_id()->value());
}

void TypeStack::push_bool_specific(Program* program, bool value) {
  TypeSet type = push_empty();
  if (value) {
    type.add(program->true_class_id()->value());
  } else {
    type.add(program->false_class_id()->value());
  }
}

void TypeStack::push_instance(unsigned id) {
  TypeSet type = push_empty();
  type.add(id);
}

void TypeStack::push(Program* program, Object* object) {
  TypeSet type = push_empty();
  if (is_heap_object(object)) {
    type.add(HeapObject::cast(object)->class_id()->value());
  } else {
    type.add(program->smi_class_id()->value());
  }
}

void TypeStack::push_block(BlockTemplate* block) {
  TypeSet type = push_empty();
  type.set_block(block);
}

} // namespace toit::compiler
} // namespace toit
