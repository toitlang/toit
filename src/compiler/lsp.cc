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

#include "lsp.h"

#include <stdio.h>

#include "../utils.h"

namespace toit {
namespace compiler {

int utf16_offset_in_line(Source::Location location) {
  int utf8_offset_in_line = location.offset_in_line;
  const uint8* text = location.source->text();
  int line_start_offset = location.line_offset;

  int result = 0;
  int source_index = line_start_offset;
  while (source_index < line_start_offset + utf8_offset_in_line) {
    int nb_bytes = Utils::bytes_in_utf_8_sequence(text[source_index]);
    source_index += nb_bytes;
    if (nb_bytes <= 3) {
      result++;
    } else {
      // Surrogate pair or 4-byte UTF-8 encoding needed above 0xFFFF.
      result += 2;
    }
  }
  return result;
}

void print_lsp_range(Source::Range range, SourceManager* source_manager) {
  auto from_location = source_manager->compute_location(range.from());
  auto to_location = source_manager->compute_location(range.to());

  ASSERT(from_location.source->absolute_path() != null);
  ASSERT(strcmp(from_location.source->absolute_path(), to_location.source->absolute_path()) == 0);

  print_lsp_range(from_location.source->absolute_path(),
                     from_location.line_number,
                     utf16_offset_in_line(from_location),
                     to_location.line_number,
                     utf16_offset_in_line(to_location));
}

void print_lsp_range(const char* path,
                     int from_line,
                     int from_column,
                     int to_line,
                     int to_column) {
  printf("%s\n", path);
  printf("%d\n%d\n", from_line - 1, from_column);
  printf("%d\n%d\n", to_line - 1, to_column);
}

} // namespace toit::compiler
} // namespace toit
