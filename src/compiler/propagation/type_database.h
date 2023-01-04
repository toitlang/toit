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
  static TypeDatabase* compute(Program* program);
  ~TypeDatabase();

  Program* program() const { return program_; }

  const std::vector<Method> methods() const;
  const std::vector<TypeSet> arguments(Method method) const;
  const TypeSet usage(int position) const;
  const TypeSet return_type(int position) const;

  std::string as_json() const;

  // Helpers for optimization phase.
  bool is_dead_method(int position) const;
  bool is_dead_call(int position) const;

  bool does_not_return(int position) const;
  bool always_throws(int position) const;
  bool never_throws(int position) const;

  // Helpers for type checking interpreter variant.
  void check_top(uint8* bcp, Object* top) const;
  void check_return(uint8* bcp, Object* value) const;
  void check_method_entry(Method method, Object** sp) const;

 private:
  Program* const program_;
  const int words_per_type_;
  std::vector<TypeStack*> types_;

  std::unordered_map<int, TypeStack*> methods_;
  std::unordered_map<int, TypeSet> usage_;
  std::unordered_map<int, TypeSet> returns_;

  static std::unordered_map<Program*, TypeDatabase*> cache_;

  TypeDatabase(Program* program, int words_per_type);

  void add_method(Method method);
  void add_argument(Method method, int n, const TypeSet type);
  void add_usage(int position, const TypeSet type);

  TypeSet copy_type(const TypeSet type);
  TypeStack* add_types_block();

  friend class TypePropagator;
};

class TypeOracle {
 public:
  explicit TypeOracle(SourceMapper* source_mapper)
      : source_mapper_(source_mapper) {}

  void seed(ir::Program* program);
  void finalize(ir::Program* program, TypeDatabase* types);

  // Helpers for optimization phase.
  bool is_dead(ir::Method* method) const;
  bool is_dead(ir::Code* code) const;
  bool is_dead(ir::Call* call) const;

  bool does_not_return(ir::Call* call) const;
  bool always_throws(ir::Typecheck* check) const;
  bool never_throws(ir::Typecheck* check) const;

 private:
  SourceMapper* const source_mapper_;
  TypeDatabase* types_ = null;

  std::vector<ir::Node*> nodes_;
  std::unordered_map<ir::Node*, ir::Node*> map_;

  void add(ir::Node* node);
  ir::Node* lookup(ir::Node* node) const;

  friend class TypeOraclePopulator;
};

} // namespace toit::compiler
} // namespace toit
