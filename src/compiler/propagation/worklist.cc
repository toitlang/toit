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
  // TODO(kasper): We should be able to get away
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

void Worklist::add(uint8* bcp, TypeScope* scope) {
  auto probe = scopes_.find(bcp);
  if (probe == scopes_.end()) {
    // Make a full copy of the scope so we can use it
    // to collect merged types from all the different
    // paths that can end up in here.
    scopes_[bcp] = scope->copy();
    unprocessed_.push_back(bcp);
  } else {
    TypeScope* existing = probe->second;
    if (existing->merge(scope, TypeScope::MERGE_LOCAL)) {
      // TODO(kasper): Try to avoid adding this if it is
      // already in the list of unprocessed items.
      unprocessed_.push_back(bcp);
    }
  }
}

Worklist::Item Worklist::next() {
  uint8* bcp = unprocessed_.back();
  unprocessed_.pop_back();
  return Item {
    .bcp = bcp,
    // The working scope is copied lazily.
    .scope = scopes_[bcp]->copy_lazily()
  };
}

} // namespace toit::compiler
} // namespace toit
