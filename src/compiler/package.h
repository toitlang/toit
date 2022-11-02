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

#pragma once

#include <string>
#include <functional>

#include "../top.h"

#include "filesystem.h"
#include "map.h"

namespace toit {
namespace compiler {

class Package {
 public:
  enum ErrorState {
    /// No error.
    OK,
    /// Not a package. Also used to indicate that a prefix doesn't have any target.
    INVALID,
    /// The package was declared, but there was an error in the package file for
    /// this package.
    ERROR,
    /// The package was declared, but couldn't be found.
    NOT_FOUND,
  };

  // The "package" id of the entry file.
  // Generally, this is the application that is compiled.
  static constexpr const char* ENTRY_PACKAGE_ID = "";

  // The package id of the SDK libraries.
  static constexpr const char* SDK_PACKAGE_ID = "<sdk>";

  // The package id of the virtual files.
  static constexpr const char* VIRTUAL_PACKAGE_ID = "<virtual>";

  // The package id for packages that had errors.
  // Used when a prefix can't be resolved.
  static constexpr const char* ERROR_PACKAGE_ID = "<error>";

  // A package id for packages that don't correspond to any real package.
  // We use this to initialize variables where we don't know the package
  // yet, or where we don't have any access to the package id.
  static constexpr const char* INVALID_PACKAGE_ID = "<invalid>";

  // Constructor must be valid, as we use the class as values in a map.
  Package() {}

  std::string id() const { return id_; }
  std::string absolute_path() const { return absolute_path_; }
  ErrorState error_state() const { return _error_state; }

  bool is_ok() const { return _error_state == OK; }

  // When a prefix is an sdk prefix then we haven't consumed the prefix yet.
  bool is_sdk_prefix() const { return id_ == std::string(SDK_PACKAGE_ID); }

  // Build the error path for the given absolute path which must be inside
  // this package.
  std::string build_error_path(Filesystem* fs, const std::string& member_absolute_path) const;

  bool is_valid() const { return _error_state != INVALID; }

  static Package invalid() { return Package(); }

  void list_prefixes(const std::function<void (const std::string& candidate)>& callback) const;

  bool has_valid_path() const {
    if (id_ == Package::ERROR_PACKAGE_ID) return false;
    if (id_ == Package::VIRTUAL_PACKAGE_ID) return false;
    return is_ok();
  }

 private:
  Package(const std::string id,
          const std::string& absolute_path,
          const std::string& absolute_error_path,
          const std::string& relative_error_path,
          ErrorState state,
          Map<std::string, std::string> prefixes)
      : id_(id)
      , absolute_path_(absolute_path)
      , _absolute_error_path(absolute_error_path)
      , _relative_error_path(relative_error_path)
      , _error_state(state)
      , prefixes_(prefixes) { }

  std::string id_ = std::string(INVALID_PACKAGE_ID);
  std::string absolute_path_ = std::string("");
  // The absolute location of the relative error path.
  // Usually the same as the absolute_path. Can be different for the entry package.
  std::string _absolute_error_path = std::string("");
  // The path we use to create error paths.
  // This is the path we used to find the absolute error path.
  // In general only relevant for the entry package.
  std::string _relative_error_path = std::string("");

  ErrorState _error_state = INVALID;

  // Mapping from prefix to package-id.
  Map<std::string, std::string> prefixes_;

  friend class PackageLock;
};

} // namespace toit::compiler
} // namespace toit
