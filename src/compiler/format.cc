// Copyright (C) 2026 Toit contributors.
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

#include <cstdlib>
#include <cstring>
#include <string>

#include "../top.h"
#include "format.h"
#include "ast.h"

namespace toit {
namespace compiler {

using namespace ast;

uint8* format_unit(Unit* unit,
                   List<Scanner::Comment> comments,
                   int* formatted_size) {
  Source* source = unit->source();
  int size = source->size();
  uint8* buffer = unvoid_cast<uint8*>(malloc(size));
  memcpy(buffer, source->text(), size);
  *formatted_size = size;
  return buffer;
}

} // namespace toit::compiler
} // namespace toit
