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

#include "trie.h"

#include "../utils.h"

namespace toit {
namespace compiler {

Trie::Trie(int id)
    : kind(Token::EOS)
    , data(Symbol::invalid())
    , _id(id)
    , _capacity(INLINED_CHILDREN)
    , _children(_inlined) {
  memset(_inlined, 0, sizeof(_inlined));
}

Trie* Trie::get(const uint8* string) {
  Trie* result = this;
  int c;
  while ((c = *string++) != '\0') {
    result = result->get(c);
  }
  return result;
}

Trie* Trie::get(const uint8* from, const uint8* to) {
  Trie* result = this;
  while (from != to) {
    result = result->get(*from++);
  }
  return result;
}

Trie* Trie::allocate(int index, int id) {
  if (index == _capacity) {
    int new_capacity = _capacity * 4;
    Trie** new_children = unvoid_cast<Trie**>(malloc(sizeof(Trie*) * new_capacity));
    memcpy(new_children, _children, sizeof(Trie*) * _capacity);
    memset(new_children + _capacity, 0, sizeof(Trie*) * (new_capacity - _capacity));
    _capacity = new_capacity;
    _children = new_children;
  }
  return _children[index] = _new Trie(id);
}

} // namespace toit::compiler
} // namespace toit
