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

#include "type_stack.h"

namespace toit {
namespace compiler {

// Forward declarations.
class BlockTemplate;
class MethodTemplate;

class TypeScope {
 public:
  explicit TypeScope(MethodTemplate* method);
  TypeScope(BlockTemplate* block, TypeScope* outer);
  ~TypeScope();

  TypeStack* top() const { return stacks_[level_]; }
  int level() const { return level_; }
  TypeScope* outer() const { return outer_; }

  TypeSet load_outer(TypeSet block, int index);
  void store_outer(TypeSet block, int index, TypeSet value);

  TypeScope* copy() const;
  bool merge(const TypeScope* other);

 private:
  const int words_per_type_;
  TypeStack** const stacks_;
  const int level_;
  TypeScope* const outer_;

  explicit TypeScope(const TypeScope* other);
};

} // namespace toit::compiler
} // namespace toit
