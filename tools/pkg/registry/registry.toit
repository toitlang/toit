import encoding.yaml
import .local
import .git
import ..file-system-view
import ..error
import ..dependency
import ..dependency.local-solver
import ..semantic-version
import ..project.package
import ..constraints
import ..utils

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

  retrieve-description url/string version/SemanticVersion -> Description:
    registries.do --values:
      if description := it.retrieve-description url version: return description
    error "Not able to find package $url with version $version"
    unreachable

  retrieve-versions url/string -> List:
    registries.do --values:
      if versions := it.retrieve-versions url: return versions
    error "Not able to find package $url in any repository"
    unreachable


abstract class Registry:
  name/string
  description-cache_ := {:}


  constructor .name:

  abstract type -> string
  abstract retrieve-description url/string version/SemanticVersion -> Description?
  abstract retrieve-versions url/string -> List?
  abstract content -> FileSystemView

  retrieve-description url/string version/SemanticVersion -> Description?:
    if not description-cache_.contains url or not description-cache_[url].contains version:
      url-cache := description-cache_.get url --if-absent=: description-cache_[url] = {:}
      desc-buffer := content.get --path=(flatten_list ["packages", url.split "/", version.stringify, "desc.yaml" ])
      url-cache[version] = desc-buffer and Description (yaml.decode desc-buffer)

    return description-cache_[url][version]

  retrieve-versions url/string -> List?:
    versions := content.get --path=(flatten_list ["packages", url.split "/"])
    if not versions is FileSystemView: return null
    semantic-versions/List := versions.list.keys.map: SemanticVersion it

    // Sort
    semantic-versions.sort --in-place

    // Reverse
    result := []
    semantic-versions.do --reversed: result.add it

    return result

  search search-string/string -> List:
    search-version := null
    if search-string.contains "@":
      split := search-string.split "@"
      search-string = split[0]
      search-version = split[1]

    // name-paths will always have size 4 and be pre- and post-fixed with null for missing search terms.
    // For example "toitlang/pkg-host" will be [null, "toitlang", "pkg-host", null]
    // And "pkg-host@1.7.1" will be [null, null, "pkg-host", "1.7.1"
    name-paths := search-string.split "/"
    paths := []
    (3 - name-paths.size).repeat:
      paths.add null
    paths.add-all name-paths
    paths.add search-version

    search-result := prefix-search_ paths (content.get "packages")

    packages := []
    search-result.do: | hub-list |
      hub := hub-list[0]
      hub-list[1].do: | repository-list |
        repository := repository-list[0]
        repository-list[1].do: | package-list |
          package := package-list[0]
          packages.add [ [ hub, repository, package ], package-list[1] ]

    packages = packages.map --in-place: | package/List versions/List |
      version := highest-version_ versions
      package-url := package.join "/"
      description := retrieve-description package-url version
      RemotePackage package-url version description

    return packages

  static highest-version_ versions/List -> SemanticVersion:
    highest := SemanticVersion versions[0]
    if versions.size == 1: return highest
    versions[1..].do:
      next := SemanticVersion it
      if highest <= next: highest = next
    return highest

  // TODO: Less lists, more classes
  static prefix-search_ paths/List files/FileSystemView -> List?:
    if paths.is-empty: return []
    if paths[0] == null:
      if paths.size == 1: // Version term
        return files.list.keys
      result := []
      files.list.do: | k v |
        if v is FileSystemView:
          sub-search := prefix-search_ paths[1..] v
          if sub-search:
            result.add [ k, sub-search ]
      return result.is-empty ? null : result
    else:
      sub-structure := files.get paths[0]
      if sub-structure:
        if paths.size == 1:
          return [ paths[0] ]
        else:
          return [[ paths[0], prefix-search_ paths[1..] sub-structure ]]
      return null


class RemotePackage:
  url/string
  version/SemanticVersion
  description/Description

  constructor .url .version .description:

  default-prefix -> string:
    return description.name

  ref-hash:
    return description.ref-hash

  stringify:
    return "$url $version $description"


class Description:
  content/Map

  cached-version_/SemanticVersion? := null
  cached-sdk-version_/List := []
  cached-dependencies_/List? := null

  constructor .content:

  name -> string: return content[NAME-KEY_]

  ref-hash -> string: return content[HASH-KEY_]

  version -> SemanticVersion:
    if not cached_version_:
      cached_version_ = SemanticVersion content[VERSION-KEY_]
    return cached_version_

  sdk-version -> Constraint?:
    if cached-sdk-version_.is-empty:
      if environment := content.get ENVIRONMENT-KEY_:
        if sdk-constraint := environment.get SDK-KEY_:
          cached-sdk-version_.add (Constraint sdk-constraint)
          return cached-sdk-version_[0]
      cached-sdk-version_.add null
    return cached-sdk-version_[0]

  dependencies -> List:
    if not cached-dependencies_:
      if not content.contains DEPENDENCIES-KEY_:
        cached-dependencies_ = []
      else:
        cached-dependencies_ =
            content[DEPENDENCIES-KEY_].map: | dep |
                PackageDependency dep[URL-KEY_] dep[VERSION-KEY_]
    return cached-dependencies_

  satisfies-sdk-version concrete-sdk-version/SemanticVersion -> bool:
    return not sdk-version or sdk-version.satisfies concrete-sdk-version

  static NAME-KEY_ ::= "name"
  static DESCRIPTION-KEY_ ::= "description"
  static LICENSE-KEY_ ::= "license"
  static URL-KEY_ ::= "url"
  static VERSION-KEY_ ::= "version"
  static ENVIRONMENT-KEY_ ::= "environment"
  static HASH-KEY_ ::= "hash"
  static DEPENDENCIES-KEY_ ::= "dependencies"
  static SDK-KEY_ ::= "sdk"


class RegistrySolver extends LocalSolver:
  constructor package-file/ProjectPackageFile:
    super package-file

  retrieve-description url/string version/SemanticVersion -> Description:
    return registries.retrieve-description url version

  retrieve-versions url/string -> List:
    return registries.retrieve-versions url

