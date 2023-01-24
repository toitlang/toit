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

#pragma once

#include "../top.h"

#include <string>

#include "filesystem.h"
#include "list.h"
#include "map.h"
#include "tar.h"

namespace toit {
namespace compiler {

class Diagnostics;

class FilesystemArchive : public Filesystem {
 public:
  FilesystemArchive(const char* path)
      : path_(path) {}

  /// Loads the given archive, caching the contained files.
  void initialize(Diagnostics* diagnostics);

  const char* entry_path() { return entry_path_; }

  bool is_absolute(const char* path) { return path[0] == '/'; }
  const char* relative_anchor(const char* path) { return cwd(); }
  char path_separator() { return '/'; }
  bool is_path_separator(char c) { return c == '/'; }
  char* root(const char* path) {
    char* result = new char[2];
    if (path[0] == '/') {
      result[0] = '/';
      result[1] = '\0';
    } else {
      result[0] = '\0';
    }
    return result;
  }
  bool is_root(const char* path) {
    return path[0] == '/' && path[1] == '\0';
  }

  const char* sdk_path() { return sdk_path_; }
  List<const char*> package_cache_paths() { return package_cache_paths_; }

  bool contains_sdk() { return contains_sdk_; }

  static bool is_probably_archive(const char* path);

 protected:
  bool do_exists(const char* path);
  bool do_is_regular_file(const char* path);
  bool do_is_directory(const char* path);

  const uint8* do_read_content(const char* path, int* size);

  const char* getcwd(char* buffer, int buffer_size) { return cwd_path_; }
  void list_directory_entries(const char* path,
                              const std::function<void (const char*)> callback);

 private:
  struct FileEntry {
    const char* content;
    int size;
  };
  struct PathInfo {
    bool exists;
    bool is_regular_file;
    bool is_directory;
  };
  const char* path_;
  bool is_initialized_ = false;

  bool contains_sdk_ = false;

  // These entries are overwritten in the initialize function.
  const char* entry_path_ = "/";
  const char* sdk_path_ = "/";
  List<const char*> package_cache_paths_;
  const char* cwd_path_ = "/";
  UnorderedMap<std::string, FileEntry> archive_files_;
  UnorderedMap<std::string, PathInfo> path_infos_;
  UnorderedMap<std::string, List<std::string>> directory_listings_;
};

} // namespace compiler
} // namespace toit
