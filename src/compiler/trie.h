// Copyright (C) 2018 Toitware ApS.
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

#include "token.h"
#include "symbol.h"
#include "../top.h"

namespace toit {
namespace compiler {

class Trie {
 public:
  explicit Trie(int id);

  Trie* get(int id) {
    int index = 0;
    while (index < capacity_) {
      Trie* child = children_[index];
      if (child == null) break;
      if (child->id_ == id) return child;
      index++;
    }
    return allocate(index, id);
  }

  Trie* get(const uint8* string);

  Trie* get(const uint8* from, const uint8* to);

  // For terminals, the kind is either a specific keyword or identifier.
  Token::Kind kind;
  Symbol data;

 private:
  int id_;
  int capacity_;
  Trie** children_;

  // Keep a couple of children inlined in the trie node.
  static const int INLINED_CHILDREN = 2;
  Trie* inlined_[INLINED_CHILDREN];

  // Allocate and fill in slot for new child.
  Trie* allocate(int index, int id);
};

} // namespace toit::compiler
} // namespace toit
