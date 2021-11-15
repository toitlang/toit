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

#include "../top.h"

#include <stdio.h>

#ifdef TOIT_POSIX
#include <sys/socket.h>
#endif
#ifdef TOIT_WINDOWS
#include <winsock.h>
#endif

#include "diagnostic.h"
#include "filesystem_socket.h"
#include "windows.h"
#include "../utils.h"

namespace toit {
namespace compiler {

char* get_executable_path();

bool FilesystemSocket::do_exists(const char* path) {
  auto info = info_for(path);
  return info.exists;
}

bool FilesystemSocket::do_is_regular_file(const char* path) {
  auto info = info_for(path);
  return info.is_regular_file;
}

bool FilesystemSocket::do_is_directory(const char* path) {
  auto info = info_for(path);
  return info.is_directory;
}

const char* FilesystemSocket::sdk_path() {
  putline("SDK PATH");
  return getline();
}

List<const char*> FilesystemSocket::package_cache_paths() {
  putline("PACKAGE CACHE PATHS");

  char* count_str = getline();
  int count = atoi(count_str);
  free(count_str);

  auto result = ListBuilder<const char*>::allocate(count);

  for (int i = 0; i < count; i++) {
    char* line = getline();
    result[i] = line;
  }
  return result;
}

const uint8* FilesystemSocket::do_read_content(const char* path, int* size) {
  auto info = info_for(path);
  *size = info.size;
  return info.content;
}

void FilesystemSocket::list_directory_entries(const char* path,
                                              const std::function<void (const char*)> callback) {
  putline("LIST DIRECTORY");
  putline(path);

  char* count_str = getline();
  int count = atoi(count_str);
  free(count_str);

  for (int i = 0; i < count; i++) {
    char* line = getline();
    callback(line);
    free(line);
  }
}

FilesystemSocket::PathInfo FilesystemSocket::info_for(const char* path) {
  std::string lookup_key(path);
  auto probe = _file_cache.find(lookup_key);
  if (probe != _file_cache.end()) return probe->second;

  putline("INFO");
  putline(path);
  char* exists_str = getline();
  bool exists = strcmp(exists_str, "true") == 0;
  free(exists_str);

  char* is_regular_str = getline();
  bool is_regular = strcmp(is_regular_str, "true") == 0;
  free(is_regular_str);

  char* is_directory_str = getline();
  bool is_directory = strcmp(is_directory_str, "true") == 0;
  free(is_directory_str);

  const char* content_size_str = getline();
  int size = atoi(content_size_str);
  uint8* content = null;
  if (size >= 0) {
    content = unvoid_cast<uint8*>(malloc(size + 1));
    int offset = 0;
    while (offset < size) {
      int n = recv(_socket, char_cast(content) + offset, size - offset, 0);
      if (n == -1) {
        fprintf(stderr, "ERROR: Unable to read entire file '%s'\n", path);
        size = 0;
        break;
      }
      offset += n;
    }
    content[size] = '\0';
  }
  PathInfo info = {
    .exists = exists,
    .is_regular_file = is_regular,
    .is_directory = is_directory,
    .size = size,
    .content = content,
  };

  _file_cache[lookup_key] = info;
  return info;
}

void FilesystemSocket::putline(const char* line) {
  int len = strlen(line);
  int offset = 0;
  while (offset < len) {
    int n = send(_socket, line + offset, len - offset, 0);
    if (n == -1) {
      FATAL("failed writing line");
    }
    offset += n;
  }

  const char nl = '\n';
  if (send(_socket, &nl, 1, 0) != 1) {
    FATAL("failed writing newline");
  }
}

char* FilesystemSocket::getline() {
  // TODO(anders): This is not that cool. Find a better way to buffer.
  char buffer[64 * 1024];

  size_t offset = 0;
  while (offset < sizeof(buffer)) {
    int n = recv(_socket, buffer + offset, 1, 0);
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

} // namespace compiler
} // namespace toit
