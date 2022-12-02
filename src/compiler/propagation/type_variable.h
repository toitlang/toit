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

#include "type_set.h"
#include "../set.h"
#include "../../top.h"

namespace toit {
namespace compiler {

// Forward declarations.
class TypePropagator;
class MethodTemplate;

class TypeVariable {
 public:
  explicit TypeVariable(int words_per_type)
      : words_per_type_(words_per_type)
      , bits_(static_cast<uword*>(malloc(words_per_type * WORD_SIZE)))
      , type_(bits_) {
    memset(bits_, 0, words_per_type * WORD_SIZE);
  }

  ~TypeVariable() {
    free(bits_);
  }

  TypeSet type() const {
    return type_;
  }

  TypeSet use(TypePropagator* propagator, MethodTemplate* user, uint8* site);
  bool merge(TypePropagator* propagator, TypeSet other);

 private:
  const int words_per_type_;
  uword* const bits_;
  TypeSet type_;

  Set<MethodTemplate*> users_;
};

} // namespace toit::compiler
} // namespace toit
