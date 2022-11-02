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

#include "../../top.h"

#include <stdio.h>

#ifdef TOIT_POSIX
#include <sys/socket.h>
#endif
#ifdef TOIT_WINDOWS
#include <winsock.h>
#endif

#include "fs_connection_socket.h"
#include "../../utils.h"

namespace toit {
namespace compiler {

char* get_executable_path();

void LspFsConnectionSocket::putline(const char* line) {
  int len = strlen(line);
  int offset = 0;
  while (offset < len) {
    int n = send(socket_, line + offset, len - offset, 0);
    if (n == -1) {
      FATAL("failed writing line");
    }
    offset += n;
  }

  const char nl = '\n';
  if (send(socket_, &nl, 1, 0) != 1) {
    FATAL("failed writing newline");
  }
}

char* LspFsConnectionSocket::getline() {
  // TODO(anders): This is not that cool. Find a better way to buffer.
  char buffer[64 * 1024];

  size_t offset = 0;
  while (offset < sizeof(buffer)) {
    int n = recv(socket_, buffer + offset, 1, 0);
    if (n != 1) {
      FATAL("failed reading line");
    }
    if (buffer[offset] == '\n') {
      char* result = unvoid_cast<char*>(malloc(offset + 1));
      memcpy(result, buffer, offset);
      result[offset] = 0;
      return result;
    }
    offset++;
  }
  FATAL("line too large\n");
}

int LspFsConnectionSocket::read_data(uint8* content, int size) {
  int offset = 0;
  while (offset < size) {
    int n = recv(socket_, char_cast(content) + offset, size - offset, 0);
    if (n == -1) return -1;
    offset += n;
  }
  return 0;
}

} // namespace compiler
} // namespace toit
