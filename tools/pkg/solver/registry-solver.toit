// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..semantic-version
import ..constraints
import ..registry
import ..registry.description
import ..error
import ..utils
import ..project.package
import encoding.yaml

class PackageConstraint:
  prefix/string
  url/string
  version-constraint/Constraint

  constructor .prefix .url .version-constraint:

class Resolved:
  sdk-version/SemanticVersion? := null
  packages/Map := {:}  // PackageDependency -> ResolvedPackage.

  constructor solution/PartialSolution:
    packages = solution.partial-packages.map: | _ v | ResolvedPackage v
    // DEBUG
    deps := solution.partial-packages.keys
    deps.sort --in-place: | a b | a.stringify.compare-to b.stringify
    m := {:}
    deps.do:
      m[it.stringify] = pps-to-map solution.partial-packages[it]

  constructor.empty:

  pps-to-map v/PartialPackageSolution: // DEBUG
    packs := {:}
    v.dependencies.do: | k v/PartialPackageSolution | packs[k.stringify] = { "version": v.solved-version.stringify }
    return { "url": v.url, "version": v.solved-version.stringify, "hash": v.ref-hash, "packages": packs }


class ResolvedPackage:
  solution_/PartialPackageSolution

  constructor .solution_:

  url -> string:
    return solution_.url

  version -> SemanticVersion:
    return solution_.solved-version

  ref-hash -> string:
    return solution_.ref-hash

  name -> string:
    return solution_.name

  dependencies -> Map:
    return solution_.dependencies.map: | _ v | ResolvedPackage v

  hash-code -> int:
    return url.hash-code + version.hash-code

  sdk-version -> Constraint?:
    return solution_.sdk-version

  operator == other/ResolvedPackage:
    return url == other.url and version == other.version


class PartialPackageSolution:
  dependencies/Map := {:}  // PackageDependency -> PartialPackageSolution.
  versions/List? := null  // of possible SemanticVersions.
  url/string
  description/Description? := null
  /**
  Whether a satisfying sdk-version was found for a version.
  Used for error reporting.
  */
  sdk-version-found/bool := false

  constructor .url/string .versions/List:

  constructor.copy other/PartialPackageSolution package-translator/IdentityMap:
    url = other.url
    description = other.description
    if other.versions:
      versions = other.versions.copy
    dependencies = copy-dependency-to-solution-map_ other.dependencies package-translator

  solved-version -> SemanticVersion:
    return description.version

  name -> string:
    return description.name

  sdk-version -> Constraint?:
    return description.sdk-version

  ref-hash -> string:
    return description.ref-hash

  satisfies dependency/PackageDependency -> bool:
    if description:
      return dependency.satisfies description.version
    else:
      filtered := dependency.filter versions
      return not filtered.is-empty

  add-source-dependency dependency/PackageDependency:
    if versions:
      versions = dependency.filter versions

  stringify:
    return "versions=$versions, solved-version: $(description ? description.version : null), $(dependencies.map: | k v | "$k->$v.solved-version, ")"

  hash-code -> int:
    return url.hash-code


class PartialSolution:
  partial-packages/Map  // PackageDependency -> PartialPackageSolution.
  unsolved-packages/Deque  // A queue of PackageDependencies that have unresolved partial solutions.
  url-to-dependencies/Map := {:}  // string -> [PackageDependency], keeping track of the same url with different constraints.
  solver/Solver

  constructor .solver .partial-packages/Map:
    unsolved-packages = Deque.from partial-packages.keys
    partial-packages.keys.do: | dependency/PackageDependency |
      append-to-list-value url-to-dependencies dependency.url dependency

  /** Performs a deep copy to support backtracking. */
  constructor.copy other/PartialSolution:
    solver = other.solver
    url-to-dependencies = other.url-to-dependencies.map: | _ v | v.copy
    unsolved-packages = Deque.from other.unsolved-packages
    package-translator := IdentityMap  // Mapping old PartialPackageSolution's to copied version.
    partial-packages = copy-dependency-to-solution-map_ other.partial-packages package-translator

  is-solution -> bool:
    return unsolved-packages.is-empty

  add-partial-package-solution
      dependency/PackageDependency
      package/PartialPackageSolution
      new-package/PartialPackageSolution:
    package.dependencies[dependency] = new-package
    partial-packages[dependency] = new-package
    add-to-set-value url-to-dependencies dependency.url dependency
    unsolved-packages.add dependency

  refine -> PartialSolution?:
    if is-solution: return this

    unsolved-dependency/PackageDependency := unsolved-packages.remove-first
    unsolved-package/PartialPackageSolution := partial-packages[unsolved-dependency]

    package-versions/List := unsolved-package.versions

    package-versions.do: | next-version/SemanticVersion |
      copy := PartialSolution.copy this
      if copy.load-dependencies unsolved-dependency next-version:
        if refined := copy.refine: return refined

    return null

  load-dependencies unresolved-dependency/PackageDependency next-version/SemanticVersion -> bool:
    description := solver.registries.retrieve-description unresolved-dependency.url next-version

    if not description.satisfies-sdk-version solver.sdk-version:
      return false

    package/PartialPackageSolution := partial-packages[unresolved-dependency]
    package.description = description
    package.versions = null

    description.dependencies.do: | dependency/PackageDependency |
      if url-to-dependencies.contains dependency.url:
        partial-package-solutions := IdentitySet
        url-to-dependencies[dependency.url].do: partial-package-solutions.add partial-packages[it]

        if partial-package := dependency.find-satisfied-package partial-package-solutions:
          partial-package.add-source-dependency dependency
          package.dependencies[dependency] = partial-package
        else:
          all-versions := solver.registries.retrieve-versions dependency.url
          dependency-versions := dependency.filter all-versions
          if dependency-versions.is-empty: return false

          // For all existing dependencies, check if the the new dependency resolves a disjoint set of versions
          url-to-dependencies[dependency.url].do: | existing-dependency/PackageDependency |
            existing-versions/List := existing-dependency.filter all-versions
            dependency-versions.do:
              if existing-versions.contains it: // TODO: Should major be checked?
                // Overlapping versions and not jointly satisfied.
                return false

          // The dependency resolves to a disjoint set of versions. Add it.
          add-partial-package-solution dependency package (PartialPackageSolution dependency.url dependency-versions)
      else:
        versions := dependency.filter (solver.registries.retrieve-versions dependency.url)
        if versions.is-empty: return false
        add-partial-package-solution dependency package (PartialPackageSolution dependency.url versions)
    return true


class Solver:
  sdk-version/SemanticVersion
  registries/Registries

  constructor .registries .sdk-version:

  solve dependencies/List-> Resolved:
    package-versions/Map := {:}  // Dependency -> list of versions.

    dependencies.do: | dependency/PackageDependency |
      versions := registries.retrieve-versions dependency.url
      versions = dependency.filter versions
      if versions.is-empty: throw "No versions for packages $dependency.url satisfies supplied constraint"

      versions.filter --in-place:
        description := registries.retrieve-description dependency.url it
        description.satisfies-sdk-version sdk-version
      if versions.is-empty: throw "No version of package $dependency.url satisfies sdk-version: $sdk-version"

      package-versions[dependency] = versions

    if package-versions.is-empty: return Resolved.empty

    partial-package-solutions := {:}
    package-versions.do: | dependency/PackageDependency versions/List |
      if not partial-package-solutions.contains dependency: // The same dependency can appear multiple
                                                            // times with different names
        partial-package-solution := PartialPackageSolution dependency.url versions
        partial-package-solutions[dependency] = partial-package-solution

    partial-solution := PartialSolution this partial-package-solutions
    if solution := partial-solution.refine: return Resolved solution
    throw "Unable to resolve dependencies"


copy-dependency-to-solution-map_ input/Map translator/IdentityMap -> Map:
  return input.map: | _ v |
    if not translator.contains v:
      copy := PartialPackageSolution.copy v translator
      translator[v] = copy
    translator[v]

