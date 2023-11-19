import host.file
import encoding.yaml

import ..dependency
import ..dependency.local-solver
import ..error
import ..registry

import .project
import .lock

class PackageFile:
  content/Map
  project/Project? := null

  static FILE_NAME ::= "package.yaml"

  constructor .project:
    content = {:}

  constructor.from-project .project:
    content = yaml.decode (file.read_content "$project.root/$FILE_NAME")

  constructor.external path/string:
    content = yaml.decode (file.read_content "$path/$FILE_NAME") or {:}

  constructor.from-buffer .project buffer/ByteArray:
    content = yaml.decode buffer

  add-remote-dependency prefix/string url/string constraint/string:
    assert: project != null
    dependencies[prefix] = {
      URL-KEY_: url,
      VERSION-KEY_: constraint
    }

  add-local-dependency prefix/string path/string:
    assert: project != null
    dependencies[prefix] = {
      PATH-KEY_: path
    }

  save:
    assert: project != null
    if content.is-empty:
      file.write_content "# Toit Package File." --path="$project.root/$FILE_NAME"
    else:
      file.write_content --path=project.root
          yaml.encode content

  dependencies -> Map:
    if not content.contains DEPENDENCIES-KEY_:
      content[DEPENDENCIES-KEY_] = {:}
    return content[DEPENDENCIES-KEY_]

  name -> string:
    return content.get NAME-KEY_ --if-absent=: error "Missing 'name' in $project.root."

  has-package package-name/string:
    return dependencies.contains package-name

  solve -> LockFile:
    assert: project != null
    solver := RegistrySolver this
    return (LockFileBuilder this solver.solve-with-local).build

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

  static DEPENDENCIES-KEY_ ::= "dependencies"
  static NAME-KEY_         ::= "name"
  static URL-KEY_          ::= "url"
  static VERSION-KEY_      ::= "version"
  static PATH-KEY_         ::= "path"

