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
      : _path(path) { }

  /// Loads the given archive, caching the contained files.
  void initialize(Diagnostics* diagnostics);

  const char* entry_path() { return _entry_path; }

  const char* sdk_path() { return _sdk_path; }
  List<const char*> package_cache_paths() { return _package_cache_paths; }

  bool contains_sdk() { return _contains_sdk; }

  static bool is_probably_archive(const char* path);

 protected:
  bool do_exists(const char* path);
  bool do_is_regular_file(const char* path);
  bool do_is_directory(const char* path);

  const uint8* do_read_content(const char* path, int* size);

  const char* getcwd(char* buffer, int buffer_size) { return _cwd_path; }
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
  const char* _path;
  bool _is_initialized = false;

  bool _contains_sdk = false;

  // These entries are overwritten in the initialize function.
  const char* _entry_path = "/";
  const char* _sdk_path = "/";
  List<const char*> _package_cache_paths;
  const char* _cwd_path = "/";
  UnorderedMap<std::string, FileEntry> _archive_files;
  UnorderedMap<std::string, PathInfo> _path_infos;
  UnorderedMap<std::string, List<std::string>> _directory_listings;
};

} // namespace compiler
} // namespace toit
