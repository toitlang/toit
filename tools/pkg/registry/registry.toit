import encoding.yaml

import cli.cache show Cache FileStore
import host.file

import .local
import .git
import ..file-system-view
import ..error
import ..solver.registry-solver
import ..solver.local-solver
import ..semantic-version
import ..project.package
import ..constraints
import ..utils

registries ::= Registries

// TODO(florian): move this cache global to a better place. It is used by many other libraries.
cache ::= Cache --app-name="toit-pkg"

/**
A collection of registries.

This class groups all registries and provides a common interface for them.
*/
class Registries:
  registries := {:}

  constructor:
    registries-map := yaml.decode
        cache.get "registries.yaml": | store/FileStore |
            toit := GitRegistry "toit" "github.com/toitware/registry" null
            store.save
                yaml.encode {
                    "toit": {
                        "url": "github.com/toitware/registry",
                        "type": "git"
                    }
                  }
    registries-map.do: | name/string map/Map |
      type := map.get "type" --if-absent=: error "Registry $name does not have a type."
      if type == "git":
        url := map.get "url" --if-absent=: error "Registry $name does not have a url."
        ref-hash := map.get "ref-hash"
        registries[name] = GitRegistry name url ref-hash
      else if type == "local":
        path := map.get "path" --if-absent=: error "Registry $name does not have a path."
        registries[name] = LocalRegistry name path
      else:
        error "Registry $name has an unknown type '$type'"

  search --registry-name/string?=null search-string/string -> RemotePackage:
    search-results := search_ registry-name search-string
    if search-results.size == 1:
      return search-results[0][1]

    if search-results.is-empty:
      // TODO(florian): implement better version error.
      error "Package '$search-string' not found (Implement version check error)."
    else:
      // TODO(florian): implement better error.
      error "Multiple packages found (Implement better error)."

    unreachable

  /**
  Searches for the given $search-string in the given $registry-name.

  If no $registry-name is given, searches in all registries.
  Returns a list of matches, where each entry is itself a list containing the
    registry name and the package.
  */
  search_ registry-name/string? search-string/string -> List:
    if not registry-name:
      search-results := []
      registries.do: | name/string registry/Registry |
        search-results.add-all
            (registry.search search-string).map: [name, it]
      return search-results
    else:
      registry/Registry := registries.get registry-name --if-absent=: error "Registry $registry-name not found."
      search-results := registry.search search-string
      return search-results.map: [registry-name, it]

  retrieve-description url/string version/SemanticVersion -> Description:
    registries.do --values:
      if description := it.retrieve-description url version: return description
    error "Not able to find package $url with version $version."
    unreachable

  retrieve-versions url/string -> List:
    registries.do --values:
      if versions := it.retrieve-versions url: return versions
    error "Not able to find package $url in any registry."
    unreachable

  add --local name/string path/string:
    if not local: throw "INVALID_ARGUEMT"
    if registries.contains name: error "Registry $name already exists."
    registries[name] = LocalRegistry name path
    save_

  add --git name/string url/string:
    if not git: throw "INVALID_ARGUEMT"
    if registries.contains name: error "Registry $name already exists."
    registries[name] = GitRegistry name url null
    registries[name].sync  // To check that the url is valid.
    save_

  remove name/string:
    if not registries.contains name: error "Registry $name does not exist."
    registries.remove name
    save_

  list:
    print "$(%-10s "Name") $(%-6s "Type") Url/Path"
    print "$(%-10s "----") $(%-6s "----") --------"
    registries.do: | name registry |
      print "$(%-10s name) $(%-6s registry.type) $(registry is GitRegistry ? registry.url : registry.path)"

  /**
  Searches for the given $search-string in all registries.

  Returns a list of all matches.
  Each match is encoded as a list of the form:
    [package-name/string, version/string, description/Map]
  */
  search --free-text search-string/string -> List:
    result := []
    registries.do: | name registry/Registry |
      result.add-all
          registry.list-all-packages.filter:  | package/List |
            package[0].contains search-string or
              package[2][Description.NAME-KEY_].contains search-string or
              package[2][Description.DESCRIPTION-KEY_].contains search-string
    return result

  list-packages -> Map:
    return registries.map: | name registry/Registry |
      { "registry" : registry, "packages": registry.list-all-packages }

  sync:
    registries.do --values: it.sync

  sync --name/string:
    registry := registries.get name --if-absent=: error "Registry $name does not exist"
    registry.sync

  save_:
    registries-map := {:}
    registries.do: | name registry/Registry |
      registries-map[name] = registry.to-map

    cache-file := cache.get-file-path "registries.yaml" : | store/FileStore | store.save #[]
    file.write_content --path=cache-file (yaml.encode registries-map)


abstract class Registry:
  name/string
  description-cache_ := {:}  // registry-name -> (Map of url -> description).

  constructor .name:

  abstract type -> string
  abstract content -> FileSystemView
  abstract to-map -> Map
  abstract sync
  abstract stringify -> string

  filter-filesystem map/Map -> Map:
    return map.filter: | k v | v is FileSystemView

  list-all-packages -> List:
    result := []

    hubs/FileSystemView := content.get --path=["packages"]
    // REVIEW(florian): we definitely migrated towards this layout, but I'm not
    // sure if we can/should insist on it. It feels like just recursively looking for all
    // 'desc.yaml' files should be enough.
    // On the other hand, it makes things more consistent. So maybe we just should.
    (filter-filesystem hubs.list).do: | hub-name hub |
      (filter-filesystem hub.list).do: | repository-name repository/FileSystemView |
        (filter-filesystem repository.list).do: | package-name package/FileSystemView |
          (filter-filesystem package.list).do: | version-name version/FileSystemView |
            desc := version.get --path=["desc.yaml"]
            if desc:
              description := yaml.decode desc
              // REVIEW(florian): we should take the package-name and version-name from the
              // description. If we insist on the layout, then we should at least warn if
              // they aren't the same.
              // TODO(florian): return a SearchResult object. Would be more efficient and easier to use.
              result.add [package-name, version-name, description]

    return result

  retrieve-description url/string version/SemanticVersion -> Description?:
    if not description-cache_.contains url or not description-cache_[url].contains version:
      url-cache := description-cache_.get url --init=: {:}
      desc-buffer := content.get --path=(flatten_list ["packages", url.split "/", version.stringify, "desc.yaml"])
      url-cache[version] = desc-buffer and Description (yaml.decode desc-buffer)

    return description-cache_[url][version]

  retrieve-versions url/string -> List?:
    // REVIEW(florian): I designed the pkg manager, with the idea that the whole registry could always be in memory.
    // Not sure that was a good idea, but shouldn't we at least cache everything we read?
    // Here I would expect to have a versions-cache.
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

