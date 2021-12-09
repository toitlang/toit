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

#include "filesystem.h"
#include "filesystem_archive.h"
#include "filesystem_local.h"

namespace toit {
namespace compiler {

class Diagnostics;

class FilesystemHybrid : public Filesystem {
 public:
  FilesystemHybrid(const char* path)
      : _use_fs_archive(FilesystemArchive::is_probably_archive(path))
      , _fs_archive(path) { }

  void initialize(Diagnostics* diagnostics);
  const char* entry_path();
  const char* sdk_path();
  List<const char*> package_cache_paths();
  bool is_absolute(const char* path);
  char path_separator();
  char* root(const char* path);

 protected:
  bool do_exists(const char* path);
  bool do_is_regular_file(const char* path);
  bool do_is_directory(const char* path);
  const uint8* do_read_content(const char* path, int* size);

  const char* getcwd(char* buffer, int buffer_size);
  void list_directory_entries(const char* path,
                              const std::function<void (const char*)> callback);

 private:
  bool _use_fs_archive;
  FilesystemLocal _fs_local;
  FilesystemArchive _fs_archive;

  template<typename T>
  T do_with_active_fs(const std::function<T (Filesystem* fs)> callback);

  template<typename T>
  T do_with_active_fs(const char* path,
                      const std::function<T (const char* path, Filesystem* fs)> callback);
};

} // namespace compiler
} // namespace toit
