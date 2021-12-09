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
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>
// For checking whether a path is a regular file.
#include <sys/types.h>
#include <dirent.h>


#include "filesystem_local.h"
#include "lock.h"
#include "util.h"
#include "../flags.h"
#include "../top.h"
#include "../utils.h"

// Old C library version of stat.
extern "C" {

extern int __xstat64(int ver, const char* path, struct stat64* stat_buf);

}

#if defined(TOIT_LINUX) && !defined(__riscv)
  #define USE_XSTAT64 1
#endif

#ifdef BUILD_64
# define STAT_VERSION 1
#else
# define STAT_VERSION 3
#endif

namespace toit {
namespace compiler {

char* get_executable_path();

bool FilesystemLocal::do_exists(const char* path) {
#ifdef USE_XSTAT64
  // Use an older version of stat, so that we can run in docker
  // containers with older glibc.
  struct stat64 path_stat;
  int stat_result = __xstat64(STAT_VERSION, path, &path_stat);
#else
  struct stat path_stat;
  int stat_result = stat(path, &path_stat);
#endif
  return stat_result == 0;
}


bool FilesystemLocal::do_is_regular_file(const char* path) {
#ifdef USE_XSTAT64
  // Use an older version of stat, so that we can run in docker
  // containers with older glibc.
  struct stat64 path_stat;
  int stat_result = __xstat64(STAT_VERSION, path, &path_stat);
#else
  struct stat path_stat;
  int stat_result = stat(path, &path_stat);
#endif
  if (stat_result == 0) {
    return S_ISREG(path_stat.st_mode);
  } else {
    return false;
  }
}

bool FilesystemLocal::do_is_directory(const char* path) {
#ifdef USE_XSTAT64
  // Use an older version of stat, so that we can run in docker
  // containers with older glibc.
  struct stat64 path_stat;
  int stat_result = __xstat64(STAT_VERSION, path, &path_stat);
#else
  struct stat path_stat;
  int stat_result = stat(path, &path_stat);
#endif
  if (stat_result == 0) {
    return S_ISDIR(path_stat.st_mode);
  } else {
    return false;
  }
}

const char* FilesystemLocal::sdk_path() {
  if (_sdk_path == null) {
    if (Flags::lib_path != null) {
      _sdk_path = Flags::lib_path;
    } else {
      // Compute the library_root based on the executable path.
      char* path = get_executable_path();
      // TODO: We should check if the current folder contains a lib folder and if not,
      //   return an appropriate error code.
      char* toit_root = ::dirname(path);
      int root_len = strlen(toit_root);
      // `dirname` might return its result in a static buffer (especially on macos), and we
      // have to copy the result back into path. (+1 for the terminating '\0' character).
      memmove(path, toit_root, root_len + 1);
      _sdk_path = path;
    }
  }
  return _sdk_path;
}

List<const char*> FilesystemLocal::package_cache_paths() {
  if (!_has_computed_cache_paths) {
    _has_computed_cache_paths = true;
    char* cache_paths = getenv("TOIT_PACKAGE_CACHE_PATHS");
    if (cache_paths != null) {
      _package_cache_paths = string_split(strdup(cache_paths), ":");
    } else {
      char* home_path = getenv("HOME");
      if (home_path == null) {
        // TODO(florian): we could use getpwuid(getuid())->pw_dir instead.
        // However, the LSP server currently only looks at the env var.
        FATAL("Couldn't determine home");
      }
      _package_cache_paths = ListBuilder<const char*>::build(
        compute_package_cache_path_from_home(home_path, this));
    }
  }
  return _package_cache_paths;
}

const char* FilesystemLocal::getcwd(char* buffer, int buffer_size) {
  return ::getcwd(buffer, buffer_size);
}

const uint8* FilesystemLocal::do_read_content(const char* path, int* size) {
  // Open the file.
  FILE* file = fopen(path, "rb");
  if (file == null) {
    return null;
  }

  // Determine the size of the file.
  if (fseek(file, 0, SEEK_END) != 0) {
    // TODO(florian): This should be returned as error-code to the compiler.
    fprintf(stderr, "ERROR: Can't seek in file %s\n", path);
    fclose(file);
    return null;
  }
  int byte_count = ftell(file);
  rewind(file);

  // Read in the entire file.
  uint8* buffer = unvoid_cast<uint8*>(malloc(byte_count + 1));
  int result = fread(buffer, 1, byte_count, file);
  fclose(file);
  if (result != byte_count) {
    fprintf(stderr, "ERROR: Unable to read entire file '%s'\n", path);
    return null;
  }
  buffer[byte_count] = '\0';
  *size = byte_count;
  return buffer;
}

void FilesystemLocal::list_directory_entries(const char* path,
                                             const std::function<void (const char*)> callback) {
  if (!is_directory(path)) return;
  DIR* dir = opendir(path);
  if (dir == null) return;
  while (true) {
    struct dirent* entry = readdir(dir);
    if (entry == null) break;
    callback(entry->d_name);
  }
  closedir(dir);
}

} // namespace compiler
} // namespace toit
