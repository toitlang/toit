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

#include "type_scope.h"
#include <vector>
#include <unordered_map>

namespace toit {
namespace compiler {

class Worklist {
 public:
  struct Item {
    uint8* bcp;
    TypeScope* scope;
  };

  Worklist(uint8* entry, TypeScope* scope, BlockTemplate* block);
  ~Worklist();

  BlockTemplate* block() const { return block_; }

  bool has_next() const { return !unprocessed_.empty(); }
  Item next();

  TypeScope* add(uint8* bcp, TypeScope* scope, bool split);

 private:
  // Code that runs while we're unwinding towards a specific target
  // is analyzed separately from the same code reached in other ways,
  // so the types only flow to the targets they can reach.
  struct Key {
    uint8* bcp;
    Unwinding* unwinding;
    bool operator==(const Key& other) const {
      return bcp == other.bcp && unwinding == other.unwinding;
    }
  };

  struct KeyHash {
    size_t operator()(const Key& key) const {
      return reinterpret_cast<size_t>(key.bcp) ^ (reinterpret_cast<size_t>(key.unwinding) >> 3);
    }
  };

  // If this worklist is for a block, contains the value of it. Null otherwise.
  BlockTemplate* const block_;

  std::vector<Key> unprocessed_;
  std::unordered_map<Key, TypeScope*, KeyHash> scopes_;
};

} // namespace toit::compiler
} // namespace toit
