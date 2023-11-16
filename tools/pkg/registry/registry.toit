import .local
import .git
import ..error

registries ::= Registries

class Registries:
  registries := {:}
  constructor:
    registries["toit"] = GitRegistry "toit" "github.com/toitware/registry"

  search --registry-name/string?=null search-string/string -> RemotePackage:
    search-results := search_ registry-name search-string
    if search-results.size == 1:
      return search-results[0][1]

    if search-results.is-empty:
      error "Error: Package '$search-string' not found (Implement version check error)"
    else:
      error "Multple packages found (Implement better error)"

    unreachable

  search_ registry-name search-string -> List:
    if not registry-name:
      search-results := []
      registries.do: | name/string registry/Registry |
        search-results.add-all
            (registry.search search-string).map: [name, it]
      return search-results
    else:
      registry/Registry := registries.get registry-name --if-absent=: error "Registry $registry-name not found"
      search-results := registry.search search-string
      return search-results.map: [registry-name, it]

abstract class Registry:
  name/string

  constructor .name:

  abstract type -> string
  abstract search search-string/string -> List

class RemotePackage:
  url/string
  version/string
  description/Description

  constructor .url .version description/Map:
    this.description = Description description

  default-prefix -> string:
    return description.name

  ref-hash:
    return description.ref-hash

  stringify:
    return "$url $version $description"

class Description:
  map/Map

  constructor .map:

  name -> string: return map[NAME-KEY_]
  ref-hash -> string: return map[HASH-KEY_]
  static NAME-KEY_ ::= "name"
  static DESCRIPTION-KEY_ ::= "description"
  static LICENSE-KEY_ ::= "license"
  static URL-KEY_ ::= "url"
  static VERSION-KEY_ ::= "version"
  static ENVIRONMENT-KEY_ ::= "environment"
  static HASH-KEY_ ::= "hash"

main:
  print
      registries.search "pkg-host"



