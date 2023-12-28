import host.file
import host.directory
import system
import fs

import .registry-solver
import ..project.package

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
abstract class LocalSolver extends Solver:
  local-packages/Map
  package-file/ProjectPackageFile

  constructor .package-file/ProjectPackageFile:
    // REVIEW(florian): I would not give the `package-file` in the constructor, but
    // rather to the `solve` method.
    local-packages = find-all-local-packages package-file
    dependencies := {}
    local-packages.do --values: | package/LocalPackage |
      dependencies.add-all package.package-file.registry-dependencies.values
    dependencies.add-all package-file.registry-dependencies.values

    // REVIEW(florian): the sdk-version is overridable from the command line.
    // the constructor could take it as an argument. That said: I haven't
    // finished reviewing yet. So maybe we change the project's sdk-version instead.
    super package-file.project.sdk-version (List.from dependencies)

  static find-all-local-packages package-file/PackageFile -> Map:
    result := {:}
    find-all-local-packages_ result package-file
    return result

  static find-all-local-packages_ result/Map package-file/PackageFile -> none:
    package-file.local-dependencies.do --values: | path/string |
      package-location := package-file.absolute-path-for-dependency path
      package-path := package-file.relative-path-for-dependency path
      local-package-file := ExternalPackageFile (fs.to-absolute package-location)
      print "package-location: $package-location, path=$path, parent=$package-file.root-dir"
      local/LocalPackage := result.get package-location --if-absent=:
        result[package-location] = LocalPackage package-location local-package-file
      local.is-absolute = local.is-absolute or directory.is_absolute_ path
      find-all-local-packages_ result local-package-file

  // REVIEW(florian): I think I would prefer if this function was also called
  // `solve` and then just called `super`.
  // If we want to allow a way to solve without local packages, then this class
  // could just add a `--local/bool=true` flag.
  solve-with-local -> LocalResult:
    return LocalResult local-packages solve


canonical path/string -> string:
  elements := path.split "/"
  canoncial-list := Deque
  prefix-back-dirs := 0
  elements.do:
    if it == "." or it == "": continue.do
    else if it == "..":
      if canoncial-list.is-empty: prefix-back-dirs++
      else: canoncial-list.remove-last
    else:
      canoncial-list.add it

  prefix := (List prefix-back-dirs "..").join "/"
  suffix := (List.from canoncial-list).join "/"

  if path.starts-with "/":
    return "/$suffix"

  if canoncial-list.is-empty: return prefix
  if prefix-back-dirs == 0: return suffix
  return "$prefix/$suffix"
