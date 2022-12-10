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

// TODO(kasper): Consider introducing a proper datatype for
// a list of concrete types - maybe coupled with the target
// method. It could form a concrete invocation of sorts and
// it could be a useful concept for methods and blocks.
#include <vector>

namespace toit {
namespace compiler {

// Forward declaration.
class BlockTemplate;

class ConcreteType {
 public:
  explicit ConcreteType(unsigned id)
      : data_((id << 1) | 1) {}

  static ConcreteType any() { return ConcreteType(); }

  bool is_block() const {
    return (data_ & 1) == 0;
  }

  bool is_any() const {
    return data_ == ANY;
  }

  bool matches(const ConcreteType& other) const {
    return data_ == other.data_;
  }

  bool matches_ignoring_blocks(const ConcreteType& other) const {
    if (is_block()) return other.is_block();
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

  static uint32 hash(Method method, const std::vector<ConcreteType>& types, bool ignore_blocks);
  static bool equals(const std::vector<ConcreteType>& x, const std::vector<ConcreteType>& y, bool ignore_blocks);

 private:
  static const uword ANY = ~0UL;
  uword data_;

  ConcreteType() : data_(ANY) {}

  explicit ConcreteType(BlockTemplate* block)
      : data_(reinterpret_cast<uword>(block)) {}

  friend class BlockTemplate;
};

} // namespace toit::compiler
} // namespace toit
