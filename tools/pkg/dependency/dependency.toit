import .version
import ..project
import ..registry

class PackageConstraint:
  prefix/string
  url/string
  version-constraint/VersionConstraint

  constructor .prefix .url .version-constraint:

  resolve-key: return "$url:$version-constraint.version.major"

class Resolved:
  sdk-version/SdkVersion? := null
  prefixes/Map := {:}
  packages/List := []

class ResolvedPackage:
  package-name/string
  name/string
  url/string
  version/Version
  hash/string

  constructor .package-name .name .url .version .hash:

solve constraints/List -> Resolved:
  // Find all depedencies
  all-dependencies := {}
  all-dependencies.add-all constraints
  previous := all-dependencies
  while true:
    next := {}
    previous.do: | constraint/PackageConstraint |
      versions := registries.versions constraint.url
      versions = constraint.version-constraint.filter versions
      versions.do: | version/Version |
        spec := registries.load-spec constraint.url version
        spec.dependecis.do: | dependecy |
          new-constraint := PackageConstraint dependecy.prefix dependecy.url (Version dependecy.version)
          if not all-dependencies.contains new-constraint:
            next.add new-constraint
    if next.is-empty: break
    all-dependencies.add-all next
    previous = next

  package-to-constraints/Map := {:}
  all-dependencies.do: | constraint/PackageConstraint |
    (package-to-constraints.get constraint.resolve-key --if-absent=: {}).add constraint


  return Resolved
