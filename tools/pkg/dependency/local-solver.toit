import host.file
import host.directory
import system

import .dependency
import ..project.package

class LocalResult:
  local-packages/Map // path/string -> LocalPackage
  repository-packages/Resolved // PackageDependency -> ResolvedPackage

  constructor .local-packages .repository-packages:

class LocalPackage:
  package-file/PackageFile

  constructor .package-file:

abstract class LocalSolver extends Solver:
  local-packages/Map
  package-file/PackageFile

  constructor .package-file/PackageFile:
    local-packages = find-all-local-packages package-file
    dependencies := {}
    local-packages.do --values: | package/LocalPackage |
      dependencies.add-all package.package-file.registry-dependencies.values
    dependencies.add-all package-file.registry-dependencies.values

    super (List.from dependencies)

  static find-all-local-packages package-file/PackageFile -> Map:
    result := {:}
    package-file.local-dependencies.do --values: | path/string |
      // TODO: Handle relative/vs absolute paths
      package-location := canonical ( package-file.project.root == "." ? path : "$package-file.project.root/$path")
      local-package-file := PackageFile.external package-location
      print "package-location: $package-location, path=$path, root=$package-file.project.root"
      result[package-location] = LocalPackage local-package-file
      local-packages_ := find-all-local-packages local-package-file
      local-packages_.do: | k v | result[k] = v
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


main:
  root := "/Users/mikkel/proj/application/esp32/stream_x/toit"
  directory.chdir root
  print
      LocalSolver.find-all-local-packages (PackageFile.external ".")