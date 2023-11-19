import ..semantic-version
import ..constraints
import ..registry
import ..error
import ..utils
import encoding.yaml

class PackageConstraint:
  prefix/string
  url/string
  version-constraint/Constraint

  constructor .prefix .url .version-constraint:


class Resolved:
  sdk-version/SemanticVersion? := null
  packages/Map := {:} // PackageDependency -> ResolvedPackage

  constructor solution/PartialSolution:
    packages = solution.partial-packages.map: | _ v | ResolvedPackage v
    // DEBUG
    m := {:}
    solution.partial-packages.do: | k v/PartialPackageSolution |
      m[k.stringify] = pps-to-map v
    print (yaml.stringify m)

  constructor.empty:
    print "EMPTY"

  pps-to-map v/PartialPackageSolution: // DEBUG
    return { "url": v.url, "version": v.solved-version.stringify, "hash": v.ref-hash, "packages": (v.dependencies.keys.map: it.stringify) }


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

  dependencis -> Map:
    return solution_.dependencies.map: | _ v | ResolvedPackage v

  hash-code -> int:
    return url.hash-code + version.hash-code

  operator == other/ResolvedPackage:
    return url == other.url and version == other.version


class PartialPackageSolution:
  dependencies/Map := {:} // Map PackageDependency to PartialPackageSolution
  versions/List? := null // List of possible SemanticVersions
  url/string
  description/Description? := null

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


/**
Represents a dependency on a package from a repository.

For convienience it contains delegate methods to contraint.
*/
class PackageDependency:
  url/string
  constraint_/string // Keep this around for easy hash-code and ==
  constraint/Constraint
  constructor .url .constraint_:
    constraint = Constraint constraint_

  filter versions/List:
    return constraint.filter versions

  satisfies version/SemanticVersion -> bool:
    return constraint.satisfies version

  find-satisfied-package packages/Set -> PartialPackageSolution?:
    packages.do: | package/PartialPackageSolution |
      if package.satisfies this:
        return package
    return null

  hash-code -> int:
    return url.hash-code + constraint_.hash-code

  operator == other -> bool:
    if other is not PackageDependency: return false
    return stringify == other.stringify

  stringify: return "$url:$constraint_"


class PartialSolution:
  partial-packages/Map // PackageDependency -> PartialPackageSolution.
  unsolved-packages/Deque // A queue of PackageDependency's that have unresolved partial solutinos.
  url-to-dependencies/Map := {:} // string -> [PackageDependency], keeping track of the same url with different constriaints.
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
    package-translator := IdentityMap // Mapping old PartialPackageSolution's to copied version
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
    description := solver.retrieve-description unresolved-dependency.url next-version

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
          all-versions := solver.retrieve-versions dependency.url
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
        versions := dependency.filter (solver.retrieve-versions dependency.url)
        if versions.is-empty: return false
        add-partial-package-solution dependency package (PartialPackageSolution dependency.url versions)
    return true


// Makes an abstract solver to allow easier testing
abstract class Solver:
  package-versions/Map := {:} // Map of Dependency to list of versions

  // Should return a list of all SemanticVersion for the package denoted by url, sorted with highest first
  abstract retrieve-versions url/string -> List

  /** Retrieve the description of a specific version */
  abstract retrieve-description url/string version/SemanticVersion -> Description

  constructor dependencies/List:
    dependencies.do: | dependency/PackageDependency |
      versions := retrieve-versions dependency.url
      versions = dependency.filter versions
      if versions.is-empty: throw "No versions for packages $dependency.url satisfies supplied constraint"
      package-versions[dependency] = versions

  solve -> Resolved:
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

