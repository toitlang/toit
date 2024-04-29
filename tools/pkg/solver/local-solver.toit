// Copyright (C) 2024 Toitware ApS.
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

import host.file
import host.directory
import system
import fs

import .registry-solver
import ..project.package
import ..registry

/**
The result of the $LocalSolver.
*/
class LocalResult:
  local-packages/Map  // absolute path/string -> LocalPackage.
  repository-packages/Resolved  // PackageDependency -> ResolvedPackage.

  constructor .local-packages .repository-packages:

/**
A package file that is located in the local file system.
*/
class LocalPackage:
  package-file/PackageFile
  is-absolute/bool := false
  location/string

  constructor .location/string .package-file:

/**
A solver that resolves all dependencies for a given $ProjectPackageFile.

Extends the $Solver, so that it also handles local "path" dependencies.
*/
class LocalSolver extends Solver:
  package-file/ProjectPackageFile

  constructor registries/Registries .package-file:
    super registries package-file.project.sdk-version

  static find-all-local-packages package-file/PackageFile -> Map:
    result := {:}
    find-all-local-packages_ result package-file
    return result

  static find-all-local-packages_ result/Map package-file/PackageFile -> none:
    package-file.local-dependencies.do --values: | path/string |
      package-location := package-file.absolute-path-for-dependency path
      package-path := package-file.relative-path-for-dependency path
      local-package-file := ExternalPackageFile (fs.to-absolute package-location)
      local/LocalPackage := result.get package-location --if-absent=:
        result[package-location] = LocalPackage package-location local-package-file
      local.is-absolute = local.is-absolute or directory.is_absolute_ path
      find-all-local-packages_ result local-package-file

  solve -> LocalResult:
    local-packages := find-all-local-packages package-file
    dependencies := {}
    local-packages.do --values: | package/LocalPackage |
      dependencies.add-all package.package-file.registry-dependencies.values
    dependencies.add-all package-file.registry-dependencies.values

    super-result := super (List.from dependencies)
    return LocalResult local-packages super-result

