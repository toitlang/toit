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

Worklist::Worklist(uint8* entry, TypeScope* scope, BlockTemplate* block)
    : block_(block) {
  // TODO(kasper): As long as we never branch to the
  // very first bytecode, we should be able to get away
  // with not copying the initial scope at all and
  // just use it as the working scope.
  Key key = { entry, scope->unwinding() };
  scopes_[key] = scope;
  unprocessed_.push_back(key);
}

Worklist::~Worklist() {
  for (auto it = scopes_.begin(); it != scopes_.end(); it++) {
    delete it->second;
  }
}

TypeScope* Worklist::add(uint8* bcp, TypeScope* scope, bool split) {
  Key key = { bcp, scope->unwinding() };
  auto probe = scopes_.find(key);
  if (probe == scopes_.end()) {
    scopes_[key] = scope;
    unprocessed_.push_back(key);
    return split ? scope->copy_lazy() : null;
  } else {
    TypeScope* existing = probe->second;
    if (existing->merge(scope, TypeScope::MERGE_LOCAL)) {
      // TODO(kasper): Try to avoid adding this if it is
      // already in the list of unprocessed items.
      unprocessed_.push_back(key);
    }
    return scope;
  }
}

Worklist::Item Worklist::next() {
  Key key = unprocessed_.back();
  unprocessed_.pop_back();
  return Item {
    .bcp = key.bcp,
    .scope = scopes_[key]->copy_lazy()
  };
}

} // namespace toit::compiler
} // namespace toit
