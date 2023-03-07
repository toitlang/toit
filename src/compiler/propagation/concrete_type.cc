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

#include "concrete_type.h"

namespace toit {
namespace compiler {

uint32 ConcreteType::hash(Method method, const std::vector<ConcreteType>& types, bool ignore_blocks) {
  uint32 result = (types.size() << 13) ^ reinterpret_cast<uword>(method.header_bcp());
  for (unsigned i = 0; i < types.size(); i++) {
    ConcreteType type = types[i];
    uword part = 0;
    if (type.is_block()) {
      part = ignore_blocks ? 0xdeadcafe : reinterpret_cast<uword>(type.block());
    } else if (type.is_any()) {
      part = 0xbeefbabe;
    } else {
      part = type.id() * 31;
    }
    result = (result * 37) ^ part;
  }
  return result;
}

bool ConcreteType::equals(const std::vector<ConcreteType>& x, const std::vector<ConcreteType>& y, bool ignore_blocks) {
  size_t size = x.size();
  if (y.size() != size) return false;
  for (unsigned i = 0; i < size; i++) {
    ConcreteType tx = x[i];
    ConcreteType ty = y[i];
    bool match = ignore_blocks ? tx.matches_ignoring_blocks(ty) : tx.matches(ty);
    if (!match) return false;
  }
  return true;
}

} // namespace toit::compiler
} // namespace toit
