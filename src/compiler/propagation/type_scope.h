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
  TypeScope(BlockTemplate* block, TypeScope* outer, bool linked);
  TypeScope(int slots, int words_per_type);
  ~TypeScope();

  TypeStack* top() const { return unwrap(wrapped_[level_]); }
  int level() const { return level_; }
  bool is_in_try_block() const { return level_linked_ >= 0; }

  MethodTemplate* method() const { return method_; }
  TypeScope* outer() const { return outer_; }

  TypeStack* at(int n) const {
    ASSERT(n >= 0);
    ASSERT(n <= level_);
    return unwrap(wrapped_[n]);
  }

  TypeSet load_outer(TypeSet block, int index);
  void store_outer(TypeSet block, int index, TypeSet value);
  void throw_maybe();

  TypeScope* copy() const;
  TypeScope* copy_lazily(int level = -1) const;

  enum MergeKind {
    MERGE_LOCAL,
    MERGE_RETURN,
    MERGE_UNWIND
  };

  bool merge(const TypeScope* other, MergeKind kind);

 private:
  const int words_per_type_;
  const int level_;

  // We keep track of the level of the innermost block scope that
  // is (potentially) linked in as a try-block. When merging types
  // for unwinding, we do not have to look at scopes nested inside
  // that because they will be skipped by the unwinding that can
  // at worst stop at the innermost linked scope.
  const int level_linked_;
  int level_linked() const { return level_linked_; }

  MethodTemplate* method_;
  TypeScope* const outer_;
  uword* const wrapped_;

  TypeScope(const TypeScope* other, int level, bool lazy);

  // References to other stacks are wrapped, so we can tell the
  // difference between stacks we have already copied and stacks
  // that must to be lazily copied when needed.
  static bool is_copied(uword wrapped) {
    return (wrapped & 1) == 1;
  }
  static TypeStack* unwrap(uword wrapped) {
    return reinterpret_cast<TypeStack*>(wrapped & ~1);
  }
  static uword wrap(TypeStack* stack, bool copied) {
    return reinterpret_cast<uword>(stack) | (copied ? 1 : 0);
  }
};

} // namespace toit::compiler
} // namespace toit
