import host.file
import host.directory

import encoding.yaml

import ..solver.registry-solver
import ..solver.local-solver
import ..error
import ..registry
import ..constraints
import ..semantic-version

import .project
import .lock

// The project package file
class ProjectPackageFile extends PackageFile:
  project/Project

  constructor.new .project:
    super {:}

  constructor.load .project:
    super (yaml.decode (file.read_content "$project.root/$PackageFile.FILE_NAME"))

  root-dir -> string:
    return project.root

  add-remote-dependency prefix/string url/string constraint/string:
    dependencies[prefix] = {
      PackageFile.URL-KEY_: url,
      PackageFile.VERSION-KEY_: constraint
    }

  add-local-dependency prefix/string path/string:
    dependencies[prefix] = {
      PackageFile.PATH-KEY_: path
    }

  remove-dependency prefix/string:
    if not dependencies.contains prefix: error "No package with prefix $prefix"
    dependencies.remove prefix

  save:
    if content.is-empty:
      file.write_content "# Toit Package File." --path=file-name
    else:
      file.write_content --path=file-name
          yaml.encode content

  solve -> LockFile:
    solver := RegistrySolver this
    return (LockFileBuilder this solver.solve-with-local).build



// An external packkage file. These are read-only
class ExternalPackageFile extends PackageFile:
  path/string

  constructor .path/string:
    super ((yaml.decode (file.read_content "$path/$PackageFile.FILE_NAME")) or {:})

  root-dir -> string:
    return path

class RepositoryPackageFile extends PackageFile:
  constructor content/ByteArray:
    super (yaml.decode content)

  root-dir -> string:
    throw "Not possible to get root dir of a repository package file"

abstract class PackageFile:
  content/Map

  static FILE_NAME ::= "package.yaml"

  constructor .content:

  abstract root-dir -> string

  static file-name root/string -> string:
    return "$root/$FILE_NAME"

  file-name -> string:
    return file-name root-dir

  root-dir-real-path-in-relation-to path/string:
    if directory.is_absolute_ root-dir: return root-dir
    return directory.realpath "$path/$root-dir"

  root-dir-relative-in-relation-to path/string:
    if directory.is_absolute_ root-dir: return root-dir
    return canonical "$path/$root-dir"

  relative-path-to project-package/ProjectPackageFile -> string:
    my-dir := root-dir
    his-dir := directory.realpath project-package.root-dir
    if his-dir == my-dir: error "Reference to self in $project-package.file-name"

    idx := 0
    while idx < my-dir.size and idx < his-dir.size and my-dir[idx] == his-dir[idx]:
      idx++

    prefix := his-dir[..idx].index-of --last "/"
    if prefix <= 0: return my-dir
    if prefix == his-dir.size: return my-dir[prefix + 1 ..]

    print (his-dir[prefix..].split --drop-empty "/")
    dotdots := (his-dir[prefix..].split  --drop-empty "/").size
    return "$("../"*dotdots)$(my-dir[prefix + 1 ..])"


  real-path-for-dependecy path/string:
    if directory.is_absolute_ path: return path
    return directory.realpath "$root-dir/$path"

  relative-path-for-dependency path/string:
    if directory.is_absolute_ path: return path
    return canonical "$root-dir/$path"


  dependencies -> Map:
    if not content.contains DEPENDENCIES-KEY_:
      content[DEPENDENCIES-KEY_] = {:}
    return content[DEPENDENCIES-KEY_]

  name -> string:
    return content.get NAME-KEY_ --if-absent=: error "Missing 'name' in $file-name."

  sdk-version -> Constraint?:
    if environment_ := environment:
      if environment_.contains SDK-KEY_:
        return Constraint environment_[SDK-KEY_]
    return null

  has-package package-name/string:
    return dependencies.contains package-name

  /** Returns a map from prefix to  PackageDependency objects */
  registry-dependencies -> Map:
    dependencies := {:}
    this.dependencies.do: | prefix/string content/Map |
      if content.contains URL-KEY_:
        dependencies[prefix] = (PackageDependency content[URL-KEY_] content[VERSION-KEY_])
    return dependencies

  /** Returns a map of prefix to strings representing the paths of the local packages */
  local-dependencies -> Map:
    dependencies := {:}
    this.dependencies.do: | prefix/string content/Map |
      if content.contains PATH-KEY_:
        dependencies[prefix] = content[PATH-KEY_]
    return dependencies

  description -> string?: return content.get DESCRIPTION-KEY_
  license -> string?: return content.get LICENSE-KEY_
  environment -> Map?: return content.get ENVIRONMENT-KEY_

  static DEPENDENCIES-KEY_ ::= "dependencies"
  static NAME-KEY_         ::= "name"
  static URL-KEY_          ::= "url"
  static VERSION-KEY_      ::= "version"
  static PATH-KEY_         ::= "path"
  static ENVIRONMENT-KEY_  ::= "environment"
  static SDK-KEY_          ::= "sdk"
  static DESCRIPTION-KEY_  ::= "description"
  static LICENSE-KEY_      ::= "license"


/**
Represents a dependency on a package from a repository.

For convienience it contains delegate methods to contraint.
*/
class PackageDependency:
  url/string
  constraint_/string // Keep this around for easy hash-code and ==
  constraint/Constraint
  constructor .url .constraint_:
    constraint = Constraint constraint_

  filter versions/List:
    return constraint.filter versions

  satisfies version/SemanticVersion -> bool:
    return constraint.satisfies version

  find-satisfied-package packages/Set -> PartialPackageSolution?:
    packages.do: | package/PartialPackageSolution |
      if package.satisfies this:
        return package
    return null

  hash-code -> int:
    return url.hash-code + constraint_.hash-code

  operator == other -> bool:
    if other is not PackageDependency: return false
    return stringify == other.stringify

  constraint-string -> string:
    return constraint_

  stringify: return "$url:$constraint_"


