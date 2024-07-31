// Copyright (C) 2024 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import ..semantic-version
import ..constraints
import ..registry
import ..registry.description
import ..error as error-lib
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

  static sdk-version-from-constraint_ sdk-constraint/Constraint? -> SemanticVersion?:
    if not sdk-constraint: return null
    if sdk-constraint.simple-constraints.size != 2 or
       sdk-constraint.simple-constraints[0].comparator != ">=" or
       sdk-constraint.simple-constraints[1].comparator != "<":
      throw "Invalid SDK constraint: $sdk-constraint"
    simple-constraint/SimpleConstraint := sdk-constraint.simple-constraints[0]
    return simple-constraint.constraint-version

  constructor solution/PartialSolution:
    packages = solution.partial-packages.map: | _ v/PartialPackageSolution | ResolvedPackage v
    solution.partial-packages.do --values: | v/PartialPackageSolution |
      if sdk-version == null: sdk-version = sdk-version-from-constraint_ v.sdk-version
      else if v.sdk-version:
         package-sdk-version := sdk-version-from-constraint_ v.sdk-version
         if package-sdk-version > sdk-version: sdk-version = package-sdk-version

  constructor.empty:

  pps-to-map_ v/PartialPackageSolution: // DEBUG
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
  versions/List? := null  // Of possible SemanticVersions.
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
    dependencies = make-copy-of-dependency-to-solution-map_ other.dependencies package-translator

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
    partial-packages = make-copy-of-dependency-to-solution-map_ other.partial-packages

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

    // Go through all versions of the unresolved-package.
    // Make a copy of the current partial solution and then fix the package to
    // the version we are currently trying. Then recursively try to refine the rest, thus
    // assigning version to the remaining packages.
    package-versions.do: | next-version/SemanticVersion |
      description := solver.registries.retrieve-description unsolved-dependency.url next-version
      if description.satisfies-sdk-version solver.sdk-version:
        copy := PartialSolution.copy this
        if copy.load-dependencies description unsolved-dependency next-version:
          if refined := copy.refine: return refined
        // Otherwise backtrack and try the next version.

    return null

  load-dependencies description/Description unresolved-dependency/PackageDependency next-version/SemanticVersion -> bool:
    package/PartialPackageSolution := partial-packages[unresolved-dependency]
    package.description = description
    package.versions = null

    report-no-version-package := : | url/string constraint/Constraint |
      solver.warn "No version of '$url' satisfies constraint '$constraint'"

    description.dependencies.do: | dependency/PackageDependency |
      // Nested block to fetch all available versions.
      // We filter out versions that don't satisfy the dependency constraint.
      retrieve-versions := :
        all-versions := solver.registries.retrieve-versions dependency.url
        if all-versions.is-empty: return false
        dependency-versions := dependency.filter all-versions
        if dependency-versions.is-empty:
          report-no-version-package.call dependency.url dependency.constraint
          return false

      if url-to-dependencies.contains dependency.url:
        partial-package-solutions := IdentitySet
        // Find the partial package-solutions for the dependency URL.
        // Some of them might already have a unique version. Others might not be fixed yet.
        url-to-dependencies[dependency.url].do: partial-package-solutions.add partial-packages[it]

        if partial-package := dependency.find-satisfied-package partial-package-solutions:
          // One partial package has at least one version that satisfies this dependency.
          // Shrink the set of all allowed versions in that partial package so it also takes the current
          // requirement into account. If it is a fixed package then 'add-source-dependency' won't
          // do anything, since the single version is known to work.
          partial-package.add-source-dependency dependency
          package.dependencies[dependency] = partial-package
        else:
          all-versions := solver.registries.retrieve-versions dependency.url
          if all-versions.is-empty: return false
          dependency-versions := dependency.filter all-versions
          if dependency-versions.is-empty:
            report-no-version-package.call dependency.url dependency.constraint
            return false

          existing-major-versions := {}
          // For all existing dependencies, check if the new dependency resolves a disjoint set of versions
          url-to-dependencies[dependency.url].do: | existing-dependency/PackageDependency |
            existing-versions/List := existing-dependency.filter all-versions
            dependency-versions.do:
              if existing-versions.contains it:
                // Overlapping versions and not jointly satisfied.
                return false
            existing-versions.do: | version/SemanticVersion |
              existing-major-versions.add version.major

          // The set of versions are disjoint. But they might have the same major version which is not allowed.
          dependency-versions.filter --in-place: | version/SemanticVersion |
            not (existing-major-versions.contains version.major)
          if dependency-versions.is-empty: return false

          // The dependency resolves to a disjoint set of versions. Add it.
          add-partial-package-solution dependency package (PartialPackageSolution dependency.url dependency-versions)
      else:
        // The first time we see this URL.
        // Add a new partial package with all the versions this requirement accepts.
        // We will later refine it (potentially trying all the versions that are possible).
        all-versions := solver.registries.retrieve-versions dependency.url
        if all-versions.is-empty: return false
        versions := dependency.filter all-versions
        if versions.is-empty:
          report-no-version-package.call dependency.url dependency.constraint
          return false
        add-partial-package-solution dependency package (PartialPackageSolution dependency.url versions)
    return true


class Solver:
  sdk-version/SemanticVersion
  registries/Registries
  reported-warnings/Set := {}
  outputter_/Lambda
  error-reporter_/Lambda
  versions-cache_ := {:}  // From url to list of all versions.

  constructor .registries .sdk-version
      --outputter/Lambda=(:: print it)
      --error-reporter/Lambda=(:: error-lib.error it):
    outputter_ = outputter
    error-reporter_ = error-reporter

  solve dependencies/List -> Resolved:
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

    partial-package-solutions := package-versions.map: | dependency/PackageDependency versions/List |
      PartialPackageSolution dependency.url versions

    partial-solution := PartialSolution this partial-package-solutions
    if solution := partial-solution.refine: return Resolved solution
    throw "Unable to resolve dependencies"

  get-versions-for url/string --constraint/Constraint? -> List:
    return versions-cache_.get url --init=:
      result := registries.retrieve-versions url
      if result.is-empty:
        warn "Package '$url' not found"
      result

  warn msg -> none:
    if reported-warnings.contains msg: return
    reported-warnings.add msg
    outputter_.call "Warning: $msg"

  error msg -> none:
    error-reporter_.call msg

/**
Makes a copy of the dependency-to-solution map $input.
Uses the $translator map to avoid creating different copies of the same object. When
  calling 'copy' recursively, the translator map is passed on. If there is eventually another
  call to this method, it can then remember which objects were already copied.
*/
make-copy-of-dependency-to-solution-map_ input/Map translator/IdentityMap=IdentityMap -> Map:
  return input.map: | _ v |
    if not translator.contains v:
      copy := PartialPackageSolution.copy v translator
      translator[v] = copy
    translator[v]
