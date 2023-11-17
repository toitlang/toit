import host.file
import encoding.yaml

import ..error

class PackageFile:
  content/Map
  path/string

  constructor .path:
    content = {:}

  constructor.from-file .path:
    content = yaml.decode (file.read_content path)

  constructor.from-buffer buffer/ByteArray:
    path = ""
    content = yaml.decode buffer

  save:
    if content.is-empty:
      file.write_content "# Toit Package File." --path=path
    else:
      file.write_content --path=path
          yaml.encode content

  dependencies -> Map:
    return content.get DEPENDENCIES-KEY_ --if-absent=: error "Corrupt package.yml file"

  name -> string:
    return content.get NAME-KEY_ --if-absent=: error "Missing 'name' in $path."

  has-package package-name/string:
    return dependencies.contains package-name

  static DEPENDENCIES-KEY_ ::= "dependencies:"
  static NAME-KEY_ ::= "name:"

class LockFile:
  content/Map
  path/string

  constructor .path:
    content = {:}

  constructor.load .path:
    content = yaml.decode (file.read_content path)

  save:
    if content.is-empty:
      file.write_content "# Toit Package File." --path=path
    else:
      file.write_content --path=path
          yaml.encode content
