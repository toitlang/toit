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

#include "type_variable.h"
#include "type_propagator.h"

namespace toit {
namespace compiler {

TypeSet TypeVariable::use(TypePropagator* propagator, MethodTemplate* user, uint8* site) {
  if (site) propagator->add_site(site, this);
  if (user) users_.insert(user);
  return type();
}

bool TypeVariable::merge(TypePropagator* propagator, TypeSet other) {
  if (!type_.add_all(other, words_per_type_)) return false;
  for (auto user : users_) {
    propagator->enqueue(user);
  }
  return true;
}

} // namespace toit::compiler
} // namespace toit
