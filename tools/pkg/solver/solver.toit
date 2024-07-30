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

import ..constraints
import ..project.package
import ..registry
import ..registry.description
import ..semantic-version

/**
The solution of the solver.
*/
class Solution:
  packages/Map  // From URL to a list of SemanticVersion instances.

  constructor .packages:

/**
Backtracking information.

An instance of this class is created when a candidate is tried, and then
  used to backtrack when the candidate doesn't work out.
*/
class UndoInformation:
  /**
  The size of the working queue when this undo information was created.

  When backtracking all additional entries in the working queue are removed.
  */
  working-queue-size/int

  /**
  The url-major (URL + major version) of the canditate that was tried.

  When backtracking this version has to be removed.
  May be null if we don't need to remove the existing version. In that
    case an earlier dependency already fixed the version.
  */
  url-major/string? := null

  constructor --.working-queue-size:

class UndoStack:
  stack_/List ::= []  // Of UndoInformation.

  push undo-information/UndoInformation:
    stack_.add undo-information

  pop -> UndoInformation:
    result := stack_.last
    stack_.resize (stack_.size - 1)
    return result

  size -> int: return stack_.size

class ContinuationStack:
  stack_/List ::= []  // Of int.

  push index/int:
    stack_.add index

  pop -> int:
    result := stack_.last
    stack_.resize (stack_.size - 1)
    return result

  size -> int: return stack_.size

class SolverState:
  /**
  The partial solution so far.

  From url-major to the precise version.
  */
  packages/Map ::= {:}

  /**
  The dependencies we are trying to satisfy.

  Dependencies on the same package may appear multiple times. In that case
    a later entry will take into account which version was chose earlier.
  */
  working-queue/List ::= []  // Of PackageDependency.

  /**
  Information necessary to continue exploring all possible packages for
    dependencies.

  Each entry is an index into the list of possible candidates.
  */
  continuations/ContinuationStack ::= ContinuationStack

  /**
  Undo information.

  The undo information is used to backtrack when a candidate doesn't work out.
  */
  undos/UndoStack ::= UndoStack

  /**
  Adds the given $dependencies to the working queue.
  */
  add-dependencies dependencies/List:
    working-queue.add-all dependencies

  /**
  Builds a solution, using the current state.
  */
  build-solution -> Solution:
    package-versions := {:}
    packages.do: | url-major/string version/SemanticVersion |
      dash-index := url-major.index-of --last "-"
      url := url-major[..dash-index]
      (package-versions.get url --init=: []).add version

    return Solution package-versions

  /**
  Returns the continuation for the given index.

  If no continuation is available, returns 0 (the first candidate).
  */
  continuation-for working-index/int -> int:
    if continuations.size == working-index + 1:
      // There exists a continuation for this entry.
      // Use it.
      return continuations.pop
    return 0

/**
A package that is available for solving.
*/
class SolverPackage:
  version/SemanticVersion
  dependencies/List  // Of PackageDependency.
  min-sdk-version/SemanticVersion?

  constructor --.version --.dependencies --.min-sdk-version:

/**
A (lazy) database of packages that are available.
*/
class SolverDb:
  registries_/Registries
  entries_/Map ::= {:}  // From url to SolverPackage.

  constructor .registries_:

  /**
  Returns a list of $SolverPackage instances for the given URL.

  The list is initially in descending order of version, but may be
    reordered by the solver.
  */
  get-solver-packages url/string -> List:
    return entries_.get url --init=:
      registry-entries := registries_.retrieve-descriptions url
      solver-packages := registry-entries.map: | entry/Description |
          min-sdk-version := entry.sdk-version
              ? entry.sdk-version.to-min-version
              : null
          SolverPackage
              --version=entry.version
              --min-sdk-version=min-sdk-version
              --dependencies=entry.dependencies
      solver-packages

/**
A simple constraint solver for the Toit package manager.

Some properties of the Toit package management system:
- Major versions of packages are treated as separate packages.
- Only one minor version of a package can be used in a project.
- The minimum SDK version is the maximum of the minimum SDK versions of all
  packages used in a project.
*/
class Solver:
  db_/SolverDb
  state_/SolverState? := null
  printed-errors_/Set ::= {}
  /**
  The sdk-version of the SDK.

  Packages that require a higher version of the SDK are rejected.
  */
  sdk-version/SemanticVersion?

  outputter_/Lambda

  /**
  Constructs a new solver.

  The solver can only be used for a single solve operation.
  */
  constructor registries/Registries --.sdk-version --outputter/Lambda:
    db_ = SolverDb registries
    outputter_ = outputter

  /**
  Solves the given dependencies.

  The $min-sdk-version specifies a constraint on the SDK version of the result.
    It typically comes from the main package.yaml file.

  Returns null if no solution was found.

  After this call the solver can not be reused.
  */
  solve dependencies/List --min-sdk-version/SemanticVersion?=null -> Solution?:
    if state_: throw "Solver can only be used once"
    state_ = SolverState

    if min-sdk-version:
      if sdk-version and sdk-version < min-sdk-version:
        warn_ "SDK version '$sdk-version' does not satisfy the minimal SDK requirement '^$min-sdk-version'"
        return null

    state_.add-dependencies dependencies
    working-index := 0

    // Solving strategy:
    // - The working queue contains dependencies that haven't been solved yet.
    //   There might already be a concrete version for them in the partial solution
    //   but we haven't checked that yet.
    // - For each entry we try all possible solutions, taking earlier selection into
    //   account. Note that some dependencies might allow multiple major versions, in
    //   which case an earlier entry with the same dependency URL might not be used.
    // - We try to find a working solution at each entry and then proceed to the next
    //   one. (Before that we add the new dependencies).
    // - The continuations queue contains the information necessary to test the next
    //   package if we don't find a solution with the current one.
    // - The undo-queue contains the backtracking information.
    while true:
      if working-index >= state_.working-queue.size:
        // We have a solution.
        return state_.build-solution

      if working-index < 0:
        // No solution was found.
        return null

      entry := state_.working-queue[working-index]
      continuation := state_.continuation-for working-index
      solve-dependency_ entry continuation
          --on-success=: | next-continuation/int undo-information/UndoInformation |
            working-index++
            state_.continuations.push next-continuation
            state_.undos.push undo-information
          --on-failure=:
            working-index--
            if state_.undos.size > 0:
              undo := state_.undos.pop
              apply-undo_ undo

  solve-dependency_ dependency/PackageDependency index/int  [--on-success] [--on-failure]:
    url := dependency.url
    available/List := db_.get-solver-packages url
    if available.is-empty:
      warn_ "Package '$url' not found"
      on-failure.call
      return

    constraint := dependency.constraint
    found-satisfying := index != 0  // We already found one last time.
    sdk-mismatch := false
    // Annoyingly we still need to run through all available packages,
    // even if an earlier entry already fixed a version. This is, because
    // the dependency might allow multiple major versions, and we only
    // use earlier selections if they have the same major version.
    while index < available.size:
      candidate/SolverPackage := available[index++]
      if not constraint.satisfies candidate.version:
        continue

      if sdk-version and candidate.min-sdk-version and sdk-version < candidate.min-sdk-version:
        sdk-mismatch = true
        continue

      found-satisfying = true
      major := candidate.version.major
      url-major := "$url-$major"
      existing := state_.packages.get url-major
      if existing and candidate.version != existing:
        // We only look at the same version as defined by an earlier dependency.
        continue

      undo := UndoInformation
          --working-queue-size=state_.working-queue.size

      if not existing:
        // First time we set a concrete version for this URL-major.
        state_.packages[url-major] = candidate.version
        state_.add-dependencies candidate.dependencies
        // If we undo this entry, we have to remove it from the partial solution.
        undo.url-major = url-major

      on-success.call index undo
      return

    if not found-satisfying:
      msg := "No version of '$url' satisfies constraint '$constraint'"
      if sdk-mismatch:
        msg = "$msg with SDK version '$sdk-version'"
      warn_ msg

    on-failure.call

  apply-undo_ undo/UndoInformation:
    if undo.working-queue-size != 0:
      state_.working-queue.resize undo.working-queue-size

    if undo.url-major:
      state_.packages.remove undo.url-major

  warn_ msg/string:
    if printed-errors_.contains msg: return
    outputter_.call "Warning: $msg"
    printed-errors_.add msg
