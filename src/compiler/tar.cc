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
#include <errno.h>
#include <limits.h>

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
  Defer free_pending_long_name { [&] { free(const_cast<char*>(long_name)); } };
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
    // Tar strings are fixed-width and aren't necessarily terminated.
    header[136] = '\0';  // Immediately after the 12-byte size field.
    errno = 0;
    char* size_end = null;
    long parsed_size = strtol(&header[124], &size_end, 8);
    if (errno != 0 || size_end == &header[124] || parsed_size < 0 || parsed_size > INT_MAX) {
      return UntarCode::other;
    }
    int size_in_bytes = static_cast<int>(parsed_size);
    char file_type = header[156];
    char* ustar = &header[257];
    char* file_name_prefix = &header[345];

    file_name_suffix[100] = '\0';
    ustar[5] = '\0';
    file_name_prefix[155] = '\0';
    if (strcmp("ustar", ustar) != 0) return UntarCode::not_ustar;

    const char* file_name;
    if (long_name != null) {
      file_name = long_name;
      long_name = null;
    } else if (file_name_prefix[0] != '\0') {
      int prefix_len = strlen(file_name_prefix);
      int suffix_len = strlen(file_name_suffix);
      char* combined_name = unvoid_cast<char*>(malloc(prefix_len + 1 + suffix_len + 1));
      if (combined_name == null) return UntarCode::other;
      memcpy(combined_name, file_name_prefix, prefix_len);
      combined_name[prefix_len] = '/';
      memcpy(&combined_name[prefix_len + 1], file_name_suffix, suffix_len + 1);
      file_name = combined_name;
    } else {
      // The header is stack-allocated and the file name must be copied to the heap.
      file_name = strdup(file_name_suffix);
    }
    if (file_name == null) return UntarCode::other;
    char* content = unvoid_cast<char*>(malloc(static_cast<size_t>(size_in_bytes) + 1));
    if (content == null) {
      free(const_cast<char*>(file_name));
      return UntarCode::other;
    }
    read_count = fread(content, 1, size_in_bytes, file);
    if (read_count != size_in_bytes) {
      free(const_cast<char*>(file_name));
      free(content);
      return UntarCode::other;
    }

    content[size_in_bytes] = '\0';  // Terminate with '\0'.
    if (file_type == '0' || file_type == '\0') {
      callback(file_name, content, size_in_bytes);
    } else if (file_type == 'L') {
      // Gnu's long-link format.
      ASSERT(strcmp("././@LongLink", file_name) == 0);
      long_name = content;  // Content was heap-allocated and can be reused in the next iteration.
      free(const_cast<char*>(file_name));
    } else {
      free(const_cast<char*>(file_name));
      free(content);
    }

    // Skip over the padded section.
    // Round up to the next 512 boundary.
    size_t rounded_up = (static_cast<size_t>(size_in_bytes) + 0x1FF) & (~static_cast<size_t>(0x1FF));
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
