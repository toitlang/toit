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

#include <string>

#include "../top.h"

#include "package.h"

#include "filesystem.h"
#include "util.h"

namespace toit {
namespace compiler {

std::string Package::build_error_path(const std::string& path) const {
  if (_id == VIRTUAL_PACKAGE_ID) {
    return path;
  }
  auto relative = Filesystem::relative(path, _absolute_error_path);
  if (_id == ENTRY_PACKAGE_ID) {
    PathBuilder builder;
    builder.join(_relative_error_path, relative);
    builder.canonicalize();
    return builder.buffer();
  }
  if (_id == SDK_PACKAGE_ID) {
    PathBuilder builder;
    builder.join("<sdk>", relative);
    return builder.buffer();
  }
  // For normal packages we prefix the relative path with the package id.
  PathBuilder builder;
  builder.join("<pkg:" + id() + ">", relative);
  return builder.buffer();
}

void Package::list_prefixes(const std::function<void (const std::string& candidate)>& callback) const{
  for (auto prefix : _prefixes.keys()) {
    callback(prefix);
  }
}

} // namespace toit::compiler
} // namespace toit
