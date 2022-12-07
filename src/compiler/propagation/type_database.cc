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

#include <sstream>

namespace toit {
namespace compiler {

static const int TYPES_BLOCK_SIZE = 1024;

TypeDatabase::TypeDatabase(Program* program, int words_per_type)
    : program_(program)
    , words_per_type_(words_per_type) {
  add_types_block();
}

TypeDatabase::~TypeDatabase() {
  for (auto it : types_) {
    delete it;
  }
}

void TypeDatabase::check_method_entry(Method method, Object** sp) const {
  int position = program_->absolute_bci_from_bcp(method.header_bcp());
  auto probe = methods_.find(position);
  if (probe == methods_.end()) {
    FATAL("method not analyzed: %d", position);
  }
  TypeStack* stack = probe->second;
  for (int i = 0; i < method.arity(); i++) {
    TypeSet type = stack->get(i);
    Object* argument = sp[1 + (method.arity() - i)];
    if (type.is_block()) {
      if (is_smi(argument)) continue;
      FATAL("method expected a block at %d: %d", i, position);
    }
    Smi* class_id = is_smi(argument)
        ? program_->smi_class_id()
        : HeapObject::cast(argument)->class_id();
    if (type.contains(class_id->value())) continue;
    FATAL("method has wrong argument type %d @ %d: %d", class_id->value(), i, position);
  }
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
    return TypeSet::invalid();
  } else {
    return probe->second;
  }
}

std::string TypeDatabase::as_json() const {
  std::stringstream out;
  out << "[\n";

  bool first = true;
  for (auto it : usage_) {
    if (first) {
      first = false;
    } else {
      out << ",\n";
    }
    std::string type_string = it.second.as_json(program_);
    out << "  {\"position\": " << it.first;
    out << ", \"type\": " << type_string << "}";
  }

  for (auto it : methods_) {
    if (first) {
      first = false;
    } else {
      out << ",\n";
    }

    int position = it.first;
    out << "  {\"position\": " << it.first;
    out << ", \"arguments\": [";

    Method method(program_->bcp_from_absolute_bci(position));
    int arity = method.arity();
    TypeStack* arguments = it.second;
    for (int i = 0; i < arity; i++) {
      if (i != 0) {
        out << ",";
      }
      TypeSet type = arguments->get(i);
      std::string type_string = type.as_json(program_);
      out << type_string;
    }
    out << "]}";
  }

  out << "\n]\n";
  return out.str();
}

void TypeDatabase::add_method(Method method) {
  int position = program_->absolute_bci_from_bcp(method.header_bcp());
  ASSERT(methods_.find(position) == methods_.end());
  methods_[position] = new TypeStack(method.arity() - 1, method.arity(), words_per_type_);
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
  usage_.emplace(position, copy_type(type));
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
