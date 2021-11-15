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

#include <string.h>

#include "tar.h"

#include "../utils.h"

namespace toit {
namespace compiler {

UntarCode untar(const char* path,
                const std::function<void (const char* name,
                                          char* source,
                                          int size)>& callback) {
  // Open the file.
  FILE* file = null;
  if (strcmp(path, "-") == 0) {
    file = stdin;
  } else {
    file = fopen(path, "rb");
  }
  if (file == null) {
    return UntarCode::not_found;
  }
  auto result = untar(file, callback);
  if (file != stdin) fclose(file);
  return result;
}

UntarCode untar(FILE* file,
                const std::function<void (const char* name,
                                          char* source,
                                          int size)>& callback) {
  static const int HEADER_SIZE = 512;
  // In GNU Tar, files that have long names use two file-entries:
  // - the first one gives the name (as contents), and
  // - the second contains the actual content of the file.
  const char* long_name = null;
  bool encountered_zero_header = false;
  while (true) {
    char header[HEADER_SIZE];
    int read_count = fread(header, 1, HEADER_SIZE, file);

    if (read_count != HEADER_SIZE) return UntarCode::other;
    bool is_zero_header = true;
    for (int i = 0; i < HEADER_SIZE; i++) {
      if (header[i] != 0) {
        is_zero_header = false;
        break;
      }
    }
    if (encountered_zero_header) {
      return is_zero_header ? UntarCode::ok : UntarCode::other;
    } else if (is_zero_header) {
      encountered_zero_header = true;
      continue;
    }

    char* file_name_suffix = &header[0];
    int size_in_bytes = strtol(&header[124], null, 8);
    char file_type = header[156];
    char* ustar = &header[257];
    const char* file_name_prefix = &header[345];

    // Trim the ustar string.
    int ustar_len = strlen(ustar);
    for (int i = ustar_len - 1; i >= 0; i--) {
      if (ustar[i] != ' ') {
        ustar[i + 1] = '\0';
        break;
      }
    }
    if (strcmp("ustar", ustar) != 0) return UntarCode::not_ustar;

    const char* file_name;
    if (long_name != null) {
      file_name = long_name;
      long_name = null;
    } else if (file_name_prefix[0] != '\0') {
      // Reuse the header.
      int prefix_len = strlen(file_name_prefix);
      int suffix_len = strlen(file_name_suffix);
      memmove(&header[prefix_len], &header[0], suffix_len);
      memmove(&header[0], file_name_prefix, prefix_len);
      header[prefix_len + suffix_len] = '\0';
      // The header is stack-allocated and the file name must be copied to the heap.
      file_name = strdup(&header[0]);
    } else {
      file_name_suffix[100] = '\0';  // In case the file was exactly 100 characters long.
      // The header is stack-allocated and the file name must be copied to the heap.
      file_name = strdup(file_name_suffix);
    }
    char* content = unvoid_cast<char*>(malloc(size_in_bytes + 1));
    read_count = fread(content, 1, size_in_bytes, file);
    if (read_count != size_in_bytes) return UntarCode::other;

    content[size_in_bytes] = '\0';  // Terminate with '\0'.
    if (file_type == '0') {
      callback(file_name, content, size_in_bytes);
    } else if (file_type == 'L') {
      // Gnu's long-link format.
      ASSERT(strcmp("././@LongLink", file_name) == 0);
      long_name = content;  // Content was heap-allocated and can be reused in the next iteration.
    }

    // Skip over the padded section.
    // Round up to the next 512 boundary.
    int rounded_up = ((size_in_bytes + 0x1FF) & (~0x1FF));
    int to_read = rounded_up - size_in_bytes;
    ASSERT(to_read <= HEADER_SIZE);
    // Reuse the header, which isn't needed anymore.
    // We use `fread` as this also works for pipes.
    read_count = fread(header, 1, to_read, file);
    if (read_count != to_read) return UntarCode::other;
  }
}

static bool _is_tar_file(FILE* file) {
  // We look for two things:
  // 1. the checksum '\0', since that mostly excludes source files.
  // 2. a "ustar" header.

  int CHECKSUM_OFFSET = 148;
  // A checksum consists of 6 digital octal values, followed by a '\0' and ' '.
  int status = fseek(file, CHECKSUM_OFFSET + 6, SEEK_SET);
  if (status < 0) return false;
  char byte;
  int read = fread(&byte, 1, 1, file);
  if (read != 1) return false;
  if (byte != '\0') return false;
  read = fread(&byte, 1, 1, file);
  if (read != 1) return false;
  if (byte != ' ') return false;

  int USTAR_OFFSET = 257;
  status = fseek(file, USTAR_OFFSET, SEEK_SET);
  if (status < 0) return false;
  // In theory we need to check for the version of the ustar, but we had a bug
  // there, so we just check for "ustar" now.
  char buffer[] = "ustar";
  int data_len = sizeof(buffer) - 1;  // Drop the trailing '\0'.
  read = fread(buffer, 1, data_len, file);
  if (read != data_len) return false;
  return strncmp("ustar", buffer, data_len) == 0;
}

bool is_tar_file(const char* path) {
  if (path == null) return false;
  FILE* file = fopen(path, "rb");
  if (file == null) return false;
  bool result = _is_tar_file(file);
  fclose(file);
  return result;
}

} // namespace toit::compiler
} // namespace toit
