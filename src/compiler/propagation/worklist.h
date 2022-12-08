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

  Worklist(uint8* entry, TypeScope* scope);
  ~Worklist();

  bool has_next() const { return !unprocessed_.empty(); }
  Item next();

  TypeScope* add(uint8* bcp, TypeScope* scope, bool split);

 private:
  std::vector<uint8*> unprocessed_;
  std::unordered_map<uint8*, TypeScope*> scopes_;
};

} // namespace toit::compiler
} // namespace toit
