// Copyright (C) 2020 Toitware ApS.
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

#include "label.h"

namespace toit {
namespace compiler {

void Label::use(int position, int height) {
  ASSERT(!is_bound());
  int use_count = uses();
  int index = use_count;
  if (index < _FIRST_USES_SIZE) {
    first_uses_[index] = position;
  } else {
    additional_uses_.push_back(position);
  }

  position_or_use_count_ = _encode_use_count(use_count + 1);

  ASSERT(use_at(uses() - 1) == position);

  ASSERT(height_ == -1 || height_ == height);
  height_ = height;
  ASSERT(height_ >= 0);
}

} // namespace toit::compiler
} // namespace toit
