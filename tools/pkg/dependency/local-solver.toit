import host.file
import host.directory
import system

import .dependency
import ..project.package

class LocalResult:
  local-packages/Map // absolute path/string -> LocalPackage
  repository-packages/Resolved // PackageDependency -> ResolvedPackage

  constructor .local-packages .repository-packages:


class LocalPackage:
  package-file/PackageFile
  absolute/bool := false
  location/string
  constructor .location/string .package-file:


abstract class LocalSolver extends Solver:
  local-packages/Map
  package-file/ProjectPackageFile

  constructor .package-file/ProjectPackageFile:
    local-packages = find-all-local-packages {:} package-file
    dependencies := {}
    local-packages.do --values: | package/LocalPackage |
      dependencies.add-all package.package-file.registry-dependencies.values
    dependencies.add-all package-file.registry-dependencies.values

    super package-file.project.sdk-version (List.from dependencies)

  static find-all-local-packages result/Map package-file/PackageFile -> Map:
    package-file.local-dependencies.do --values: | path/string |
      package-location := package-file.real-path-for-dependecy path
      package-path := package-file.relative-path-for-dependency path
      local-package-file := ExternalPackageFile package-location
      print "package-location: $package-location, path=$path, parent=$package-file.root-dir"
      local/LocalPackage := result.get package-location --if-absent=:
        result[package-location] = LocalPackage package-location local-package-file
      local.absolute = local.absolute or directory.is_absolute_ path
      find-all-local-packages result local-package-file
    return result

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
