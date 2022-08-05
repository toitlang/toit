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
#include "../utils.h"

#include "filesystem.h"
#include "scanner.h"
#include "sources.h"
#include "util.h"

namespace toit {
namespace compiler {

const char* Filesystem::cwd() {
  if (_cwd == null) {
    char buffer[PATH_MAX];
    auto result = getcwd(buffer, PATH_MAX);
    _cwd = strdup(result);
  }
  return _cwd;
}

const char* Filesystem::library_root() {
  if (_library_root == null) {
    auto sdk = sdk_path();
    const char* LIB_SUFFIX = "lib";
    PathBuilder builder(this);
    builder.join(sdk);
    int sdk_length = builder.length();
    builder.join(LIB_SUFFIX);
    if (is_directory(builder.c_str())) {
      _library_root = builder.strdup();
    } else {
      builder.reset_to(sdk_length);
      builder.join("..", "lib");
      builder.canonicalize();
      // Always assign the string, without testing.
      // If the path is wrong there will be an error very soon, because the compiler can't
      // find the core library.
      _library_root = builder.strdup();
    }
  }
  return _library_root;
}

const char* Filesystem::vessel_root() {
  if (_vessel_root == null) {
    auto sdk = sdk_path();
    const char* VESSEL_SUFFIX = "vessels";
    PathBuilder builder(this);
    builder.join(sdk);
    int sdk_length = builder.length();
    builder.join(VESSEL_SUFFIX);
    if (is_directory(builder.c_str())) {
      _vessel_root = builder.strdup();
    } else {
      builder.reset_to(sdk_length);
      builder.join("..", "vessels");
      builder.canonicalize();
      // Always assign the string, without testing.
      // If the path is wrong there will be an error very soon, because the compiler can't
      // find the vessel.
      _vessel_root = builder.strdup();
    }
  }
  return _vessel_root;
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
      // Drop double slashes.
      i++;
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
  // Drop trailing path seperator.
  // There can only be one.
  if (path[canonical_pos - 1] == path_separator()) {
    canonical_pos--;
  }
  if (canonical_pos == 0) {
    path[canonical_pos++] = is_absolute ? path_separator() : '.';
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
  auto probe = _intercepted.find(std::string(path));
  if (probe == _intercepted.end()) return do_is_regular_file(path);
  return true;
}

bool Filesystem::is_directory(const char* path) {
  auto probe = _intercepted.find(std::string(path));
  if (probe == _intercepted.end()) return do_is_directory(path);
  return false;
}

bool Filesystem::exists(const char* path) {
  auto probe = _intercepted.find(std::string(path));
  if (probe == _intercepted.end()) return do_exists(path);
  return true;
}

const uint8* Filesystem::read_content(const char* path, int* size) {
  auto probe = _intercepted.find(std::string(path));
  if (probe == _intercepted.end()) return do_read_content(path, size);
  *size = probe->second.size;
  return probe->second.content;
}

void Filesystem::register_intercepted(const std::string& path, const uint8* content, int size) {
  _intercepted[path] = {
    .content = content,
    .size = size,
  };
}

void Filesystem::list_toit_directory_entries(const char* path,
                                             const std::function<void (const char*, bool is_directory)> callback) {
  list_directory_entries(path, [&](const char* entry) {
    // TODO(florian): We would like to check here, whether the `full_path` is a directory
    // or not. However, we are not allowed to do another filesystem request
    // while we are still doing the `list_directory_entries` call.
    for (int i = 0; true; i++) {
      char c = entry[i];
      if (c == '\0') {
        // Didn't find any '.'.
        // TODO(florian): We should check whether this is actually a directory.
        callback(entry, true);
        return;
      }
      if (c == '.') {
        // TODO(florian): we should check whether this entry is a directory.
        //    If yes, then we should not do the callback and just return.

        // Even if the file ends with '.toit', we can't have empty basenames.
        if (i == 0) return;
        if (strcmp(&entry[i], ".toit") == 0) {
          char* without_extension = unvoid_cast<char*>(malloc(i + 1));
          strncpy(without_extension, entry, i);
          without_extension[i] = '\0';
          callback(without_extension, false);
        }
        return;
      }
      if (i == 0 && !is_identifier_start(c)) return;
      if (i != 0 && !is_identifier_part(c)) return;
    }
  });
}

} // namespace compiler
} // namespace toit
