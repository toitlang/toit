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

#include <string.h>
#include <string>

#include "filesystem.h"
#include "list.h"
#include "util.h"

namespace toit {
namespace compiler {

List<const char*> string_split(const char* str, const char* delim) {
  return string_split(strdup(str), delim);
}

List<const char*> string_split(char* str, const char* delim) {
  ListBuilder<const char*> builder;
  char* saveptr = null;
  while (true) {
    char* part = strtok_r(str, delim, &saveptr);
    if (part == null) break;
    builder.add(part);
    str = null;  // Only the first call to strtok_r should have the string.
  }
  return builder.build();
}

void PathBuilder::canonicalize() {
  // With C++11 we can, in theory, modify the buffer directly, but it feels
  // brittle.
  auto copy = ::strdup(_buffer.c_str());
  _fs->canonicalize(copy);
  _buffer.assign(copy);
  free(copy);
}

} // namespace compiler
} // namespace toit
