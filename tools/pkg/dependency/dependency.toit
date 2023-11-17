import ..semantic-version
import ..constraints
import ..project
import ..project.package
import ..registry
import ..error

class PackageConstraint:
  prefix/string
  url/string
  version-constraint/Constraint

  constructor .prefix .url .version-constraint:


class Resolved:
  sdk-version/SemanticVersion? := null
  prefixes/Map := {:}
  packages/List := []


class ResolvedPackage:
  package-name/string
  url/string
  version/SemanticVersion
  prefixes/Map

  constructor .package-name .url .version .prefixes:

class PartialPackageSolution:
  prefixes/Map // url to index in resolved list/free list
  versions/List
  constructor .versions .prefixes={:}:

class PackageSolution:
  prefixes/Map := {:}
  version/SemanticVersion
  constructor .version .prefixes:

class PartialSolution:
  fixed-versions/Map // -> url to list of PackageSolutions
  free-versions/Map // -> url to list of list of PartialPackageSolutions
  solver/Solver

  constructor .solver .fixed-versions .free-versions:

  is-solution -> bool: return free-versions.is-empty

  is-fixed url/string: return fixed-versions.contains url

  if-free url/string: return free-versions.contains url

  fixed-satisfied url/string contraint/Constraint -> int:
    fixed-list := fixed-versions[url]
    fixed-list.

  refine -> bool:
    while not is-solution:
      free-package := free-versions.first
      free-package-versions := free-versions[free-versions]
      free-versions.remove free-package

      found-one := false
      for i := 0; i < free-package-versions.size; i++:
        free-version/SemanticVersion := free-package-versions[i]
        fixed-versions[free-package] = free-version
        new-free-versions := load-dependencies free-package free-version
        if not new-free-versions: continue
        found-one = true
        free-versions = new-free-versions
        break

      if not found-one: return false

    return true

  load-dependencies package/string version/SemanticVersion -> Map:
    new-free-versions := free-versions.copy
    (solver.retrieve-dependencies package version).do: | referred-package/string constraint-string/string |
      constraint := Constraint constraint-string
      if fixed-versions.contains referred-package:
        if not constraint.satisfies fixed-versions[referred-package]:
          return null // version has a conflict
      else if free-versions.contains referred-package:
        refined-free-versions := constraint.filter free-versions[referred-package]
        if refined-free-versions.is-empty:
          return null // that version also had a conflict
        else:
          new-free-versions[referred-package] = refined-free-versions
      else:
        new-free-versions[referred-package] = solver.retrieve-versions referred-package
    return new-free-versions


// Makes an abstract solver to allow easier testing
abstract class Solver:
  package-versions/Map := {:} // mapping package-urls to a list of versions
  package/PackageFile
  core-package-constraints := []

  // Should return a list of all SemanticVersion for the package denoted by url, sorted with highest first
  abstract retrieve-versions url/string -> List

  // Retrieve the dependencise as a list of [ url, constraint-as-string ] elements
  abstract retrieve-dependencies url/string version/SemanticVersion -> List

  constructor .package:
    package.dependencies.do: | prefix/string content/Map |
      package-constraint := PackageConstraint prefix content["url"] (Constraint content["version"])
      core-package-constraints.add package-constraint
      versions := retrieve-versions package-constraint.url
      versions = package-constraint.version-constraint.filter versions
      if versions.is-empty: throw "No packages satisfies constraint $content["version"] for package $package-constraint.url"
      package-versions[package-constraint.url] = versions

  solve -> Resolved:
    partial-solution := PartialSolution this {:} (package-versions.map: | k v | [ PartialPackageSolution it ])
    if not partial-solution.refine: throw "No solutions found for package dependencies"
    return Resolved

