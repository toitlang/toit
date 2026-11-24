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

#include "../zone.h"

#include "return_peephole.h"

namespace toit {
namespace compiler {

using namespace ir;

Expression* return_peephole(Return* node) {
  if (node->value()->is_If()) {
    auto old_if = node->value()->as_If();
    // Push the `return` into the `if`.
    // The new returns must leave the same block or method as the original
    // one, so they keep its depth.
    auto new_if = zone_new<If>(old_if->condition(),
                          zone_new<Return>(old_if->yes(), node->depth(), node->range()),
                          zone_new<Return>(old_if->no(), node->depth(), node->range()),
                          node->range());
    return new_if;
  }
  return node;
}

} // namespace toit::compiler
} // namespace toit
