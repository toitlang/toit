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

#include <functional>
#include <limits.h>
#include "filesystem_hybrid.h"

namespace toit {
namespace compiler {
/// Loads the given archive, caching the contained files.
void FilesystemHybrid::initialize(Diagnostics* diagnostics) {
  // Doesn't cost to initialize the local filesystem.
  _fs_local.initialize(diagnostics);
  if (_use_fs_archive) {
    _fs_archive.initialize(diagnostics);
  }
}

const char* FilesystemHybrid::entry_path() {
  auto f = [&](Filesystem* fs) { return fs->entry_path(); };
  return do_with_active_fs<const char*>(f);
}

char FilesystemHybrid::path_separator() {
  auto f = [&](Filesystem* fs) { return fs->path_separator(); };
  return do_with_active_fs<char>(f);
}

char* FilesystemHybrid::root(const char* path) {
  auto f = [&](Filesystem* fs) { return fs->root(path); };
  return do_with_active_fs<char*>(f);
}

bool FilesystemHybrid::is_absolute(const char* path) {
  auto f = [&](const char* path, Filesystem* fs) { return fs->is_absolute(path); };
  return do_with_active_fs<bool>(path, f);
}

bool FilesystemHybrid::do_exists(const char* path) {
  auto f = [&](const char* path, Filesystem* fs) { return fs->exists(path); };
  return do_with_active_fs<bool>(path, f);
}

bool FilesystemHybrid::do_is_regular_file(const char* path) {
  auto f = [&](const char* path, Filesystem* fs) { return fs->is_regular_file(path); };
  return do_with_active_fs<bool>(path, f);
}

bool FilesystemHybrid::do_is_directory(const char* path) {
  auto f = [&](const char* path, Filesystem* fs) { return fs->is_directory(path); };
  return do_with_active_fs<bool>(path, f);
}

const uint8* FilesystemHybrid::do_read_content(const char* path, int* size) {
  auto f = [&](const char* path, Filesystem* fs) { return fs->read_content(path, size); };
  return do_with_active_fs<const uint8*>(path, f);
}

const char* FilesystemHybrid::sdk_path() {
  auto f = [&](Filesystem* fs) { return fs->sdk_path(); };
  return do_with_active_fs<const char*>(f);
}

List<const char*> FilesystemHybrid::package_cache_paths() {
  auto f = [&](Filesystem* fs) { return fs->package_cache_paths(); };
  return do_with_active_fs<List<const char*>>(f);
}

const char* FilesystemHybrid::getcwd(char* buffer, int buffer_size) {
  auto f = [&](Filesystem* fs) { return fs->getcwd(buffer, buffer_size); };
  return do_with_active_fs<const char*>(f);
}

void FilesystemHybrid::list_directory_entries(const char* path,
                                              const std::function<void (const char*)> callback) {
  auto f = [&](const char* path, Filesystem* fs) {
    return fs->list_directory_entries(path, callback);
  };
  return do_with_active_fs<void>(path, f);
}

template<typename T>
T FilesystemHybrid::do_with_active_fs(const std::function<T (Filesystem* fs)> callback) {
  if (_use_fs_archive) return callback(&_fs_archive);
  return callback(&_fs_local);
}

template<typename T>
T FilesystemHybrid::do_with_active_fs(const char* path,
                                      const std::function<T (const char* path, Filesystem* fs)> callback) {
  if (_use_fs_archive) {
    if (path == null || _fs_archive.contains_sdk()) {
      return callback(path, &_fs_archive);
    }
    const char* sdk_path = _fs_archive.sdk_path();
    size_t sdk_path_len = strlen(sdk_path);
    if (strncmp(path, sdk_path, sdk_path_len) == 0 &&
        (sdk_path[sdk_path_len - 1] == _fs_archive.path_separator() || path[sdk_path_len] == _fs_archive.path_separator())) {
      // Replace the archive's SDK path with the local SDK path and
      // let the local filesystem do the work.
      char local_path[PATH_MAX];
      const char* local_sdk_path = _fs_local.sdk_path();
      snprintf(local_path, PATH_MAX, "%s%c%s", local_sdk_path, _fs_archive.path_separator(), &path[sdk_path_len]);
      local_path[PATH_MAX - 1] = '\0';
      return callback(local_path, &_fs_local);
    }
    return callback(path, &_fs_archive);
  }
  return callback(path, &_fs_local);
}

} // namespace compiler
} // namespace toit
