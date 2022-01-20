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

#include "multiplex_stdout.h"

#include <stdio.h>

namespace toit {
namespace compiler {

static void checked_fwrite(const void* data,
                           int size,
                           const char* error_message = "Couldn't write data") {
  int written_bytes = fwrite(data, 1, size, stdout);
  if (written_bytes != size) FATAL(error_message);
}

void LspWriterMultiplexStdout::printf(const char* format, va_list& arguments) {
  va_list copy;
  va_copy(copy, arguments);
  int32 needed_bytes = static_cast<int32>(vsnprintf(null, 0, format, arguments));
  checked_fwrite(&needed_bytes, sizeof(needed_bytes));
  int written_bytes = vprintf(format, copy);
  if (written_bytes < 0) {
    perror("multi-printf");
  }
  if (written_bytes != needed_bytes) {
    fprintf(stderr, "Written %d, needed: %d, format: %s\n", written_bytes, needed_bytes, format);
    FATAL("Unexpected vprintf return value. Write failed?");
  }
}

void LspWriterMultiplexStdout::write(const uint8* data, int size) {
  int32 size32 = static_cast<int32>(size);
  checked_fwrite(&size32, sizeof(size32));
  checked_fwrite(data, size);
}

void LspFsConnectionMultiplexStdout::putline(const char* line) {
  int len = static_cast<int>(strlen(line));
  int32 size = static_cast<int32>(len) + 1; // +1 for the newline.
  // Mark as cming from the FS protocol:
  size = -size;
  checked_fwrite(&size, sizeof(size));
  checked_fwrite(line, len);
  int written_char = fputc('\n', stdout);
  if (written_char != '\n') FATAL("Couldn't write newline");
  fflush(stdout);
}

char* LspFsConnectionMultiplexStdout::getline() {
  // TODO(florian): we should never need that much.
  const int MAX_LINE_SIZE = 64 * 1024;
  char buffer[MAX_LINE_SIZE];
  // Add a marker to make sure we don't run out of space in the line.
  buffer[MAX_LINE_SIZE - 1] = 'a';
  char* result = fgets(buffer, MAX_LINE_SIZE, stdin);
  if (result != buffer) FATAL("Couldn't read line");
  if (buffer[MAX_LINE_SIZE - 1] != 'a') FATAL("Line too long");
  int len = strlen(buffer);
  // Drop the '\n'.
  return strndup(buffer, len - 1);
}

int LspFsConnectionMultiplexStdout::read_data(uint8* content, int size) {
  int read_bytes = fread(content, 1, size, stdin);
  if (read_bytes != size) return -1;
  return 0;
}

} // namespace toit::compiler
} // namespace toit
