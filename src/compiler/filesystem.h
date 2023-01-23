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

#include <functional>
#include <string>

#include "../top.h"
#include "../utils.h"

#include "map.h"

namespace toit {
namespace compiler {

class Diagnostics;

class Filesystem {
 public:
  virtual ~Filesystem() { free(const_cast<char*>(cwd_)); }

  /// Can be called multiple times.
  /// Subclasses must ensure that multiple calls don't lead to problems.
  virtual void initialize(Diagnostics* diagnostics) = 0;

  virtual const char* entry_path() = 0;

  // This function should return the path that contains the 'lib' directory.
  // For historic reasons it may also be the path to the `bin` folder, and the compiler
  // searches for `../lib`.
  virtual const char* sdk_path() = 0;
  virtual List<const char*> package_cache_paths() = 0;

  virtual bool is_absolute(const char* path) = 0;
  // The path the non-absolute path is relative to.
  // On Posix systems this is equal to `cwd`.
  // On Windows, it can be `cwd`, or a drive (like "c:"), if the path starts with '\' or '/'.
  virtual const char* relative_anchor(const char* path) {
    return cwd();
  }
  virtual char path_separator() { return '/'; }
  // On Windows both '/' and '\\' are path separators. It's thus not
  // recommended to compare to path_separator().
  virtual bool is_path_separator(char c) { return 'c' == '/'; }
  // May return the empty string if the path is not absolute.
  virtual char* root(const char* path) {
    char* result = new char[2];
    if (path[0] == '/') {
      result[0] = '/';
      result[1] = '\0';
    } else {
      result[0] = '\0';
    }
    return result;
  }
  virtual bool is_root(const char* path) {
    return path[0] == '/' && path[1] == '\0';
  }

  bool is_regular_file(const char* path);
  bool is_directory(const char* path);
  bool exists(const char* path);
  const uint8* read_content(const char* path, int* size);

  // List the directory entries that are relevant for Toit.
  // Specifically, Toit is only interested in:
  // - toit files. (`x.toit`), which are listed without the extension.
  // - directories, as they might contain other toit files.
  // In both cases the identifier must be valid.
  // This function leaks memory and should not be used frequently.
  void list_toit_directory_entries(const char* path,
                                   const std::function<void (const char*, bool is_directory)> callback);

  const char* cwd();

  const char* library_root();
  const char* vessel_root();

  /// Registers an intercepted file.
  /// The path must be absolute.
  void register_intercepted(const std::string& path, const uint8* content, int size);

  // A simple canonicalizer, that goes through the path and merges '/xyz/../' into
  // '/'. For example `a/b/c/../../d` becomes `a/d`.
  // Also removes double '//' and '/./'
  // Does *not* canonicalize virtual paths (see [SourceManager::is_virtual_file]).
  void canonicalize(char* path);

  // Returns the relative path of [path] with respect to [to].
  std::string relative(const std::string& path, const std::string& to);

  // Copies the directory part (without the `/`) into `path`.
  // The target must be big enough to contain the dirname. Otherwise it is truncated.
  static void dirname(const char* file_path, char* dir_path, int dir_path_size);

 protected:
  virtual bool do_is_regular_file(const char* path) = 0;
  virtual bool do_is_directory(const char* path) = 0;
  virtual bool do_exists(const char* path) = 0;
  virtual const uint8* do_read_content(const char* path, int* size) = 0;

  virtual const char* getcwd(char* buffer, int buffer_size) = 0;
  virtual void list_directory_entries(const char* path,
                                      const std::function<void (const char*)> callback) = 0;

  friend class FilesystemHybrid;

 private:
  struct InterceptedFile {
    const uint8* content;
    int size;
  };

  std::string _relative(const std::string& path, std::string to);

  UnorderedMap<std::string, InterceptedFile> intercepted_;
  const char* library_root_ = null;
  const char* vessel_root_ = null;
  const char* cwd_ = null;
};

} // namespace compiler
} // namespace toit
