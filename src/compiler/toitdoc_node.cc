// Copyright (C) 2019 Toitware ApS.
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

#include "toitdoc_node.h"

namespace toit {
namespace compiler {
namespace toitdoc {

void Visitor::visit(Node* node) {
  node->accept(this);
}

#define DECLARE(name)                                           \
void Visitor::visit_##name(name* node) {                        \
}
TOITDOC_NODES(DECLARE)
#undef DECLARE

} // namespace toit::compiler::toitdoc
} // namespace toit::compiler
} // namespace toit
