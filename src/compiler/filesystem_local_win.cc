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

#include "../top.h"

#ifdef TOIT_WINDOWS

#include <errno.h>
#include <sys/param.h>
#include <libgen.h>
#include <unistd.h>
#include <shlwapi.h>

#include "filesystem_local.h"
#include "sources.h"

namespace toit {
namespace compiler {

// We need to pick between '\' and '/', and '\' is still more common on Windows.
static const char PATH_SEPARATOR = '\\';

// We accept both '/' and '\' as path separators.
static bool is_path_separator(char c) {
  return c == '/' || c == '\\';
}

char* FilesystemLocal::get_executable_path() {
  char* path = _new char[MAX_PATH];
  auto length = GetModuleFileName(NULL, path, MAX_PATH);
  path[length] = '\0';
  return path;
}

// Returns the size of the root prefix of the given path.
// Returns 0 if the path doesn't have any root prefix.
// Accepted roots are:
// - drives: `c:\` and `c:/`. We do not accept 'c:' here.
// - the double '\\' of a network path: `\\Machine1` or `\\wsl$`. In this
//   case we consider `\\` to be the root path.
//   Contrary to the file path (like "c:\") the returned root includes more
//   than just one drive, but that's more in spirit with the original root
//   path anyway.
// - a virtual file, with the VIRTUAL_FILE_PREFIX.
// Note that drive roots ('/' or '\') are not absolute, as they are
// relative to the drive.
static int root_prefix_length(const char* path) {
  if (SourceManager::is_virtual_file(path)) {
    return strlen(SourceManager::VIRTUAL_FILE_PREFIX);
  }
  int length = strlen(path);
  if (length == 0) return 0;
  if (is_path_separator(path[0]) {
    if (length == 1) return 0;  // Drive root is not absolute.
    if (path[1] == path[0]) return 2;  // Network path.
      return 0;
  }
  if (length < 3) return 0;
  bool is_ascii_drive = ('a' <= path[0] && path[0] <= 'z') || ('A' <= path[0] && path[0] <= 'Z');
  if (is_ascii_drive && path[1] == ':' && is_path_separator(path[2])) {
    return 3;  // Drive root.
  }
  return 0;
}

bool FilesystemLocal::is_absolute(const char* path) {
  return root_prefix_length(path) != 0;
}

char FilesystemLocal::path_separator() {
  return PATH_SEPARATOR;
}

char* FilesystemLocal::root(const char* path) {
  int prefix_length = root_prefix_length(path);
  ASSERT(prefix_length != 0);
  char* result = new char[prefix_length + 1];
  memcpy(result, path, prefix_length);
  result[prefix_length] = '\0';
  return result;
}

bool FilesystemLocal::is_root(const char* path) {
  int prefix_length = root_prefix_length(path);
  if (prefix_length == 0) return false;
  return static_cast<int>(strlen(path)) == prefix_length;
}


char* FilesystemLocal::to_local_path(const char* path) {
  if (path == null) return null;
  char* result = strdup(path);
  int length = strlen(path);
  for (int i = 0; i < length; i++) {
    if (result[i] == '/') result[i] = PATH_SEPARATOR;
  }
  return result;
}

} // namespace toit::compiler
} // namespace toit

#endif // TOIT_WINDOWS
