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

#include <string>
#include <functional>

#include "../top.h"

#include "diagnostic.h"
#include "list.h"
#include "map.h"
#include "package.h"
#include "set.h"
#include "sources.h"
#include "filesystem.h"

namespace toit {
namespace compiler {

class PackageLock {
 public:
  // Returns the package that contains the given path.
  // The given path must be absolute.
  // Returns "" if the path is in no package.
  Package package_for(const std::string& path, Filesystem* fs) const;

  // Reads the lock-file.
  // If [lock_file_path] is "", assumes the file doesn't exists and creates a
  // default PackageLock, as if the lock-file was empty.
  static PackageLock read(const std::string& lock_file_path,
                          const char* entry_path,
                          SourceManager* source_manager,
                          Filesystem* fs,
                          Diagnostics* diagnostics);

  bool has_errors() const { return _has_errors; }

  // Resolves the prefix inside the given package.
  //
  // The caller should check the [Package::error_state] to determine whether the
  // resolution was successfull.
  Package resolve_prefix(const Package& package, const std::string& prefix) const;

  // Null if no lock_file was found/given.
  Source* lock_file_source() const { return _lock_file_source; }

  void list_sdk_prefixes(const std::function<void (const std::string& candidate)>& callback) const;

  std::string sdk_constraint() const { return _sdk_constraint; }

 private:
  PackageLock(Source* source,
              const std::string& sdk_constraint,
              const Map<std::string, Package>& packages,
              const Set<std::string>& sdk_prefixes,
              bool hasErrors);

  // The source of the lock-file. Null if not found.
  Source* _lock_file_source;

  // Whether the package-lock file had errors.
  // This does not include resolution errors.
  // This field is only true if we couldn't parse the lock file and thus are
  // not using some information from it.
  bool _has_errors;

  // The sdk is implicitly imported without a prefix. We use this
  // set as a fall-back when a package doesn't have any explicit mapping for
  // a prefix.
  Set<std::string> _sdk_prefixes;

  // For each package-id a mapping from prefix to entry.
  // Does not contain the virtual package.
  const Map<std::string, Package> _packages;

  // A map from path to package-id.
  // The cache will be seeded with the absolute paths of the packages, and then
  // filled up with new paths when the [package_for] function encounters new ones.
  mutable Map<std::string, std::string> _path_to_package_cache;

  // The SDK constraint for this application.
  std::string _sdk_constraint;
};

/// Finds the lock-file relative to [source_path] if not null. Otherwise uses the
/// current working directory.
/// Returns "" if no lock file was found.
std::string find_lock_file(const char* source_path,
                           Filesystem* fs);

/// Tries to find the lock-file in the given directory [dir].
/// Returns "" if no lock file was found.
std::string find_lock_file_at(const char* dir,
                             Filesystem* fs);

const char* compute_package_cache_path_from_home(const char* home, Filesystem* fs);

} // namespace toit::compiler
} // namespace toit
