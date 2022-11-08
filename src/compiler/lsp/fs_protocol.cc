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

#include "fs_protocol.h"

namespace toit {
namespace compiler {

const char* LspFsProtocol::sdk_path() {
  connection_->putline("SDK PATH");
  return connection_->getline();
}

List<const char*> LspFsProtocol::package_cache_paths() {
  connection_->putline("PACKAGE CACHE PATHS");

  char* count_str = connection_->getline();
  int count = atoi(count_str);
  free(count_str);

  auto result = ListBuilder<const char*>::allocate(count);

  for (int i = 0; i < count; i++) {
    char* line = connection_->getline();
    result[i] = line;
  }
  return result;
}

void LspFsProtocol::list_directory_entries(const char* path,
                                           const std::function<void (const char*)> callback) {
  connection_->putline("LIST DIRECTORY");
  connection_->putline(path);

  char* count_str = connection_->getline();
  int count = atoi(count_str);
  free(count_str);

  for (int i = 0; i < count; i++) {
    char* line = connection_->getline();
    callback(line);
    free(line);
  }
}

LspFsProtocol::PathInfo LspFsProtocol::fetch_info_for(const char* path) {
  connection_->putline("INFO");
  connection_->putline(path);
  char* exists_str = connection_->getline();
  bool exists = strcmp(exists_str, "true") == 0;
  free(exists_str);

  char* is_regular_str = connection_->getline();
  bool is_regular = strcmp(is_regular_str, "true") == 0;
  free(is_regular_str);

  char* is_directory_str = connection_->getline();
  bool is_directory = strcmp(is_directory_str, "true") == 0;
  free(is_directory_str);

  const char* content_size_str = connection_->getline();
  int size = atoi(content_size_str);
  uint8* content = null;
  if (size >= 0) {
    content = unvoid_cast<uint8*>(malloc(size + 1));
    int n = connection_->read_data(content, size);
    if (n == -1) {
      fprintf(stderr, "ERROR: Unable to read entire file '%s'\n", path);
      size = 0;
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

  return info;
}

} // namespace toit::compiler
} // namespace toit
