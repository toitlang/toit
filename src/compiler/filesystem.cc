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

#include <libgen.h>
#include <string.h>
#include <vector>
#include <limits.h>

#include "../top.h"
#include "../flags.h"
#include "../utils.h"

#include "filesystem.h"
#include "filesystem_local.h"
#include "scanner.h"
#include "sources.h"
#include "util.h"

namespace toit {
namespace compiler {

const char* Filesystem::cwd() {
  if (cwd_ == null) {
    char buffer[PATH_MAX];
    auto result = getcwd(buffer, PATH_MAX);
    cwd_ = strdup(result);
  }
  return cwd_;
}

const char* Filesystem::library_root() {
  if (library_root_ == null && Flags::lib_path != null) {
      library_root_ = FilesystemLocal::to_local_path(Flags::lib_path);
  } else if (library_root_ == null) {
    auto sdk = sdk_path();
    PathBuilder builder(this);
    builder.join(sdk, "lib", "toit", "lib");
    library_root_ = builder.strdup();
  }
  return library_root_;
}

const char* Filesystem::vessel_root() {
  if (vessel_root_ == null) {
    auto sdk = sdk_path();
    PathBuilder builder(this);
    builder.join(sdk, "lib", "toit", "vessels");
    vessel_root_ = builder.strdup();
  }
  return vessel_root_;
}

void Filesystem::canonicalize(char* path) {
  if (path[0] == '\0') return;
  if (SourceManager::is_virtual_file(path)) return;

  bool is_absolute = this->is_absolute(path);

  std::vector<int> slashes;  // Keep track of previous slashes.
  int path_len = strlen(path);
  bool at_slash = false;
  if (!is_absolute) {
    at_slash = true;
    slashes.push_back(-1);
  }

  int canonical_pos = 0;
  int i = 0;
  while (i < path_len) {
    if (at_slash && path[i] == path_separator()) {
#ifndef TOIT_WINDOWS
      i++;
#else
      // Drop double slashes, unless we are on Windows and this is the first
      // beginning of the path.
      // A windows path that starts with '//' or '\\' (but not '/\' or '\/') is
      // the root of a network share. We must keep them.
      if (i == 1 && path[0] == path[1]) {
        // Remove the first slash. It doesn't count for .. operations.
        slashes.pop_back();
        at_slash = i;
        path[canonical_pos++] = path[i++];
      } else {
        i++;
      }
#endif
    } else if (at_slash &&
               path[i] == '.' &&
               (path[i + 1] == path_separator() || path[i + 1] == '\0')) {
      // Drop '.' segments
      i += 2;
    } else if (at_slash &&
               path[i] == '.' &&
               path[i + 1] == '.' &&
               (path[i + 2] == path_separator() || path[i + 2] == '\0')) {
      // Discard the previous segment (between the last two slashes).
      if (slashes.size() < 2) {
        // We don't have any earlier segment.
        if (!is_absolute) {
          // Copy them over.
          path[canonical_pos++] = path[i++];
          path[canonical_pos++] = path[i++];
          path[canonical_pos++] = path[i++];
          // It's not a problem if `canonical_pos` is one after the '\0', but it
          //   feels cleaner (and more resistant to future changes) if we fix it.
          if (path[canonical_pos - 1] == '\0') canonical_pos--;
        }  else { // Otherwise just drop them.
          i += 3;
        }
      } else {
        // Reset to the last '/'.
        slashes.pop_back();
        canonical_pos = slashes.back() + 1;
        i += 3;
      }
    } else {
      if (path[i] == path_separator()) {
        slashes.push_back(canonical_pos);
      }
      at_slash = path[i] == path_separator();
      path[canonical_pos++] = path[i++];
    }
  }
  // Drop trailing path separator unless it's the root.
  path[canonical_pos] = '\0';
  if (canonical_pos == 0) {
    path[canonical_pos++] = '.';
  } else if (!is_root(path) && path[canonical_pos - 1] == path_separator()) {
    // There can only be one trailing path separator.
    canonical_pos--;
  }
  path[canonical_pos] = '\0';
}

std::string Filesystem::_relative(const std::string& path, std::string to) {
  ASSERT(!path.empty() && is_absolute(path.c_str()));
  ASSERT(!to.empty() && is_absolute(to.c_str()));
  if (path == to) return std::string(".");
  PathBuilder builder(this);
  while (true) {
    if (path.rfind(to, 0) == 0 && // Starts with. (Reverse find at position 0).
        path[to.size()] == path_separator()) {
      builder.join(path.substr(to.size() + 1));
      return builder.buffer();
    }
    auto last_sep = to.rfind(path_separator());
    to = to.substr(0, last_sep);
    builder.join("..");
  }
}

std::string Filesystem::relative(const std::string& path, const std::string& to) {
  ASSERT(!path.empty() && is_absolute(path.c_str()));
  ASSERT(!to.empty() && is_absolute(to.c_str()));
  // Canonicalize both paths first.
  // The easiest is to use the PathBuilder for that.
  PathBuilder path_builder(this);
  path_builder.add(path);
  path_builder.canonicalize();
  PathBuilder to_builder(this);
  to_builder.add(to);
  to_builder.canonicalize();
  return _relative(path_builder.buffer(), to_builder.buffer());
}

void Filesystem::dirname(const char* file_path, char* dir_path, int dir_path_size) {
  strncpy(dir_path, file_path, dir_path_size);
  dir_path[dir_path_size - 1] = '\0';
  // `dirname` may modify the given path. It also requires the result to be
  //   copied (as it could be a statically allocated buffer).
  char* dirnamed = ::dirname(dir_path);
  int length = strlen(dirnamed);
  // Truncate the result if it doesn't fit. This could also be an ASSERT.
  if (length > dir_path_size - 1) length = dir_path_size - 1;
  memmove(dir_path, dirnamed, length);
  dir_path[length] = '\0';
}

bool Filesystem::is_regular_file(const char* path) {
  auto probe = intercepted_.find(std::string(path));
  if (probe == intercepted_.end()) return do_is_regular_file(path);
  return true;
}

bool Filesystem::is_directory(const char* path) {
  auto probe = intercepted_.find(std::string(path));
  if (probe == intercepted_.end()) return do_is_directory(path);
  return false;
}

bool Filesystem::exists(const char* path) {
  auto probe = intercepted_.find(std::string(path));
  if (probe == intercepted_.end()) return do_exists(path);
  return true;
}

const uint8* Filesystem::read_content(const char* path, int* size) {
  auto probe = intercepted_.find(std::string(path));
  if (probe == intercepted_.end()) return do_read_content(path, size);
  *size = probe->second.size;
  return probe->second.content;
}

void Filesystem::register_intercepted(const std::string& path, const uint8* content, int size) {
  intercepted_[path] = {
    .content = content,
    .size = size,
  };
}

void Filesystem::list_toit_directory_entries(const char* path,
                                             const std::function<bool (const char*, bool is_directory)> callback) {
  list_directory_entries(path, [&](const char* entry) {
    // TODO(florian): We would like to check here, whether the `full_path` is a directory
    // or not. However, we are not allowed to do another filesystem request
    // while we are still doing the `list_directory_entries` call.
    IdentifierValidator validator;
    for (int i = 0; true; i++) {
      char c = entry[i];
      if (c == '\0') {
        // Didn't find any '.'.
        // TODO(florian): We should check whether this is actually a directory.
        return callback(entry, true);
      }
      if (c == '.') {
        // TODO(florian): we should check whether this entry is a directory.
        //    If yes, then we should not do the callback and just return.

        // Even if the file ends with '.toit', we can't have empty basenames.
        if (i == 0) return true;
        bool should_continue = true;
        if (strcmp(&entry[i], ".toit") == 0) {
          char* without_extension = unvoid_cast<char*>(malloc(i + 1));
          strncpy(without_extension, entry, i);
          without_extension[i] = '\0';
          const char* canonicalized = IdentifierValidator::canonicalize(without_extension, i);
          if (canonicalized != without_extension) free(without_extension);
          should_continue = callback(canonicalized, false);
          free(const_cast<char*>(canonicalized));
        }
        return should_continue;
      }
      if (!validator.check_next_char(c, [&]() { return entry[i + 1]; })) return true;
    }
  });
}

} // namespace compiler
} // namespace toit
