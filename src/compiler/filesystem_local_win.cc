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

// We need to pick between '\' and '/'. As much as I hate it,
// '\' is still more common on Windows.
static char PATH_SEPARATOR = '\\';

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

bool FilesystemLocal::is_absolute(const char* path) {
  if (SourceManager::is_virtual_file(path)) return true;
  int length = strlen(path);
  if (length < 3) return false;
  // Either a Windows drive like "c:\", or a network path "\\Machine1".
  // Network paths also include the WSL drive.
  return (path[1] == ':' && is_path_separator(path[2])) ||
      (is_path_separator(path[0]) && is_path_separator(path[1]));
}

char FilesystemLocal::path_separator() {
  return PATH_SEPARATOR;
}

char* FilesystemLocal::root(const char* path) {
  assert(is_absolute(path));
  if (path[1] == ':') {
    // Something like "c:\".
    char* result = new char[4];
    memcpy(result, path, 3);
    result[3] = '\0';
    return result;
  }
  // A network path like "\\Machine1" (including "\\wsl$\" for WSL).
  // Contrary to the file path (like "c:\") the returned root includes more
  // than just one drive, but that's more in spirit with the original root
  // path anyway.
  return strdup("\\\\");
}

bool FilesystemLocal::is_root(const char* path) {
  int length = static_cast<int>();
  if (length < 3) return false;
  // Something like "c:\".
  if (path[1] == ':') {
    return path[0] != '\n' && path[1] == ':' && is_path_separator(path[2]) && path[3] == '\0';
  }
  // A network path like '\\Machine1'.
  return is_path_separator(path[0]) && is_path_separator(path[1]) && path[2] == '\0';
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
