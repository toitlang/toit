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

#include "worklist.h"

namespace toit {
namespace compiler {

Worklist::Worklist(uint8* entry, TypeScope* scope) {
  // TODO(kasper): As long as we never branch to the
  // very first bytecode, we should be able to get away
  // with not copying the initial scope at all and
  // just use it as the working scope.
  scopes_[entry] = scope;
  unprocessed_.push_back(entry);
}

Worklist::~Worklist() {
  for (auto it = scopes_.begin(); it != scopes_.end(); it++) {
    delete it->second;
  }
}

TypeScope* Worklist::add(uint8* bcp, TypeScope* scope, bool split) {
  auto probe = scopes_.find(bcp);
  if (probe == scopes_.end()) {
    scopes_[bcp] = scope;
    unprocessed_.push_back(bcp);
    return split ? scope->copy() : null;
  } else {
    TypeScope* existing = probe->second;
    if (existing->merge(scope, TypeScope::MERGE_LOCAL)) {
      // TODO(kasper): Try to avoid adding this if it is
      // already in the list of unprocessed items.
      unprocessed_.push_back(bcp);
    }
    return scope;
  }
}

Worklist::Item Worklist::next() {
  uint8* bcp = unprocessed_.back();
  unprocessed_.pop_back();
  return Item {
    .bcp = bcp,
    .scope = scopes_[bcp]->copy()
  };
}

} // namespace toit::compiler
} // namespace toit
