import .local
import .git
import ..error
import ..dependency
import ..dependency.local-solver
import ..semantic-version
import ..project.package
import ..constraints

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

  constructor .name:

  abstract type -> string
  abstract search search-string/string -> List
  abstract retrieve-description url/string version/SemanticVersion -> Description?
  abstract retrieve-versions url/string -> List?


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
  constructor package-file/PackageFile:
    super package-file

  retrieve-description url/string version/SemanticVersion -> Description:
    return registries.retrieve-description url version

  retrieve-versions url/string -> List:
    return registries.retrieve-versions url

