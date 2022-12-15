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

#include "../ir.h"
#include "../../objects.h"

#include <unordered_map>
#include <vector>
#include <string>

namespace toit {

class Program;

namespace compiler {

class TypeStack;
class SourceMapper;

class TypeDatabase {
 public:
  static TypeDatabase* compute(Program* program, SourceMapper* source_mapper);
  ~TypeDatabase();

  const std::vector<Method> methods() const;
  const std::vector<TypeSet> arguments(Method method) const;
  const TypeSet usage(int position) const;
  const TypeSet return_type(int position) const;

  std::string as_json() const;

  // ...
  bool is_dead(ir::Method* method) const;
  bool does_not_return(ir::Call* call) const;

  void check_top(uint8* bcp, Object* top) const;
  void check_return(uint8* bcp, Object* value) const;
  void check_method_entry(Method method, Object** sp) const;

 private:
  Program* const program_;
  SourceMapper* const source_mapper_;

  const int words_per_type_;
  std::vector<TypeStack*> types_;

  std::unordered_map<int, TypeStack*> methods_;
  std::unordered_map<int, TypeSet> usage_;
  std::unordered_map<int, TypeSet> returns_;

  static std::unordered_map<Program*, TypeDatabase*> cache_;

  TypeDatabase(Program* program, SourceMapper* source_mapper, int words_per_type);

  void add_method(Method method);
  void add_argument(Method method, int n, const TypeSet type);
  void add_usage(int position, const TypeSet type);

  TypeSet copy_type(const TypeSet type);
  TypeStack* add_types_block();

  friend class TypePropagator;
};

} // namespace toit::compiler
} // namespace toit
