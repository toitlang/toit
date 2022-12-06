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

#include "type_database.h"
#include "type_propagator.h"
#include "type_stack.h"

namespace toit {
namespace compiler {

static const int TYPES_BLOCK_SIZE = 1024;

TypeDatabase::TypeDatabase(Program* program, int words_per_type)
    : program_(program)
    , words_per_type_(words_per_type)
    , empty_(null) {
  TypeStack* initial = add_types_block();
  initial->push_empty();
  empty_ = initial->get(0);
}

TypeDatabase* TypeDatabase::compute(Program* program) {
  TypePropagator propagator(program);
  TypeDatabase* types = new TypeDatabase(program, propagator.words_per_type());
  propagator.propagate(types);
  return types;
}

const std::vector<Method> TypeDatabase::methods() const {
  std::vector<Method> result;
  for (auto it : methods_) {
    Method method(program_->bcp_from_absolute_bci(it.first));
    result.push_back(method);
  }
  return result;
}

const std::vector<TypeSet> TypeDatabase::arguments(Method method) const {
  int position = program_->absolute_bci_from_bcp(method.header_bcp());
  std::vector<TypeSet> result;
  auto probe = methods_.find(position);
  if (probe != methods_.end()) {
    TypeStack* arguments = probe->second;
    for (int i = 0; i < method.arity(); i++) {
      result.push_back(arguments->get(i));
    }
  }
  return result;
}

const TypeSet TypeDatabase::usage(int position) const {
  auto probe = usage_.find(position);
  if (probe == usage_.end()) {
    return empty_;
  } else {
    return probe->second;
  }
}

void TypeDatabase::add_method(Method method) {
  int position = program_->absolute_bci_from_bcp(method.header_bcp());
  ASSERT(methods_.find(position) == methods_.end());
  methods_[position] = new TypeStack(-1, method.arity(), words_per_type_);
}

void TypeDatabase::add_argument(Method method, int n, const TypeSet type) {
  int position = program_->absolute_bci_from_bcp(method.header_bcp());
  auto probe = methods_.find(position);
  ASSERT(probe != methods_.end());
  TypeStack* arguments = probe->second;
  arguments->set(n, type);
}

void TypeDatabase::add_usage(int position, const TypeSet type) {
  ASSERT(usage_.find(position) == usage_.end());
  usage_.emplace(position, type);
}

TypeSet TypeDatabase::copy_type(const TypeSet type) {
  TypeStack* stack = types_.back();
  if (stack->available() == 0) stack = add_types_block();
  stack->push(type);
  return stack->local(0);
}

TypeStack* TypeDatabase::add_types_block() {
  TypeStack* stack = new TypeStack(-1, TYPES_BLOCK_SIZE, words_per_type_);
  types_.push_back(stack);
  return stack;
}

} // namespace toit::compiler
} // namespace toit
