// Copyright (C) 2021 Toitware ApS.
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

#ifdef TOIT_POSIX

#include <libgen.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>
// For checking whether a path is a regular file.
#include <sys/types.h>

#include "filesystem_local.h"
#include "lock.h"
#include "util.h"
#include "../flags.h"
#include "../top.h"
#include "../utils.h"

namespace toit {
namespace compiler {

bool FilesystemLocal::is_absolute(const char* path) {
  return path[0] == '/';
}

const char* FilesystemLocal::relative_anchor(const char* path) {
  ASSERT(!is_absolute(path));
  return cwd();
}

char FilesystemLocal::path_separator() {
  return '/';
}

bool FilesystemLocal::is_path_separator(char c) {
  return c == '/';
}

char* FilesystemLocal::root(const char* path) {
    char* result = new char[2];
    if (path[0] == '/') {
      result[0] = '/';
      result[1] = '\0';
    } else {
      result[0] = '\0';
    }
    return result;
}

bool FilesystemLocal::is_root(const char* path) {
    return path[0] == '/' && path[1] == '\0';
}

char* FilesystemLocal::to_local_path(const char* path) {
  if (path == null) return null;
  return strdup(path);
}

} // namespace compiler
} // namespace toit

#endif
