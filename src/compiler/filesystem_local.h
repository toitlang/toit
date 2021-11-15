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

namespace toit {
namespace compiler {

class FilesystemLocal : public Filesystem {
 public:
  void initialize(Diagnostics* diagnostics) { }

  const char* entry_path() { return null; }

  /// If there is a sdk-path, uses it to compute the library root.
  /// Otherwise computes the library root based on the executable path.
  const char* sdk_path();
  List<const char*> package_cache_paths();

  /// Computes the executable path.
  ///
  /// Returns a malloced data structure that should be freed
  ///   by the caller with `delete []`.
  static char* get_executable_path();

 protected:
  bool do_exists(const char* path);
  bool do_is_regular_file(const char* path);
  bool do_is_directory(const char* path);
  const uint8* do_read_content(const char* path, int* size);

  const char* getcwd(char* buffer, int buffer_size);
  void list_directory_entries(const char* path,
                              const std::function<void (const char*)> callback);

 private:
  const char* _sdk_path = null;
  List<const char*> _package_cache_paths;
  bool _has_computed_cache_paths = false;
};

} // namespace compiler
} // namespace toit
