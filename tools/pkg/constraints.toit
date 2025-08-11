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

import .semantic-version
import .parsers.constraint-parser
import .parsers.semantic-version-parser

class Constraint:
  simple-constraints/List
  source/string
  hash-code_/int? := null

  constructor --.simple-constraints --.source:

  static parse source/string -> Constraint:
    return parse source --on-error=: throw it

  static parse source/string [--on-error] -> Constraint:
    parsed := (ConstraintParser source).constraints --consume-all --on-error=on-error
    constraints := []
    parsed.do: | constraint/ConstraintParseResult |
      version := SemanticVersion.from-parse-result constraint.semantic-version
      if constraint.prefix == "^":
        // All versions compatible with the given version.
        if version.major != 0:
          constraints.add (SimpleConstraint ">=" version)
          constraints.add (SimpleConstraint "<" (SemanticVersion --major=version.major + 1))
        else:
          // If the major version is 0, then the minor version may not be increased.
          constraints.add (SimpleConstraint ">=" version)
          constraints.add (SimpleConstraint "<" (SemanticVersion --major=version.major --minor=version.minor + 1))
      else if constraint.prefix == "~" or constraint.prefix == "~>":
        constraints.add (SimpleConstraint ">=" version)
        constraints.add (SimpleConstraint "<" (SemanticVersion --major=version.major --minor=version.minor + 1))
      else if constraint.prefix == "":
        constraints.add (SimpleConstraint "=" version)
      else:
        constraints.add (SimpleConstraint constraint.prefix version)
    return Constraint --simple-constraints=constraints --source=source

  static parse-range source/string -> Constraint:
    parser := SemanticVersionParser source --allow-missing-minor
    parse-result := parser.semantic-version --consume-all
    triple := parse-result.triple.triple
    constraints := []
    if not triple[1]:
      // No minor.
      constraints.add (SimpleConstraint ">=" (SemanticVersion --major=triple[0]))
      constraints.add (SimpleConstraint "<" (SemanticVersion --major=triple[0] + 1))
    else if not triple[2]:
      // No patch.
      constraints.add (SimpleConstraint ">=" (SemanticVersion --major=triple[0] --minor=triple[1]))
      constraints.add (SimpleConstraint "<" (SemanticVersion --major=triple[0] --minor=triple[1] + 1))
    else:
      constraints.add (SimpleConstraint "=" (SemanticVersion.from-parse-result parse-result))

    return Constraint --simple-constraints=constraints --source=source

  satisfies version/SemanticVersion -> bool:
    simple-constraints.do:
      if not it.satisfies version:
        return false
    return true

  filter versions/List -> List:
    return versions.filter: satisfies it

  first-satisfying versions/List -> SemanticVersion?:
    versions.do: | version/SemanticVersion |
      if satisfies version:
        return version
    return null

  stringify -> string:
    return source

  to-string -> string:
    if simple-constraints.size == 2 and
        simple-constraints[0].comparator == ">=" and
        simple-constraints[1].comparator == "<":
      min/SemanticVersion := simple-constraints[0].constraint-version
      max/SemanticVersion := simple-constraints[1].constraint-version
      if max.patch == 0 and max.minor == 0 and min.major + 1 == max.major:
        return "^$min"
      if max.patch == 0 and min.major == max.major and min.minor + 1 == max.minor:
        return "~$min"
    return (simple-constraints.map: it.to-string).join ","

  operator == other -> bool:
    if other is not Constraint: return false
    // We simplify our life by requiring the constraints to be in the same order.
    return simple-constraints == other.simple-constraints

  hash-code -> int:
    if not hash-code_:
      hash := 1831
      simple-constraints.do: | constraint/SimpleConstraint |
        hash = hash * 31 + constraint.hash-code
      hash-code_ = hash
    return hash-code_

  /**
  Returns the minimum version that satisfies the constraint.

  This constraint must be of the form `">=x.y.z,<a.b.c"` in which case
    it returns `x.y.z`.
  */
  to-min-version -> SemanticVersion:
    if simple-constraints.size != 2 or
        (simple-constraints[0] as SimpleConstraint).comparator != ">=" or
        (simple-constraints[1] as SimpleConstraint).comparator != "<":
      throw "Unexpected SDK constraint"
    simple/SimpleConstraint := simple-constraints[0]
    return simple.constraint-version

class SimpleConstraint:
  comparator/string
  constraint-version/SemanticVersion
  check/Lambda
  constructor .comparator/string .constraint-version:
    this.check = CONSTRAINT-COMPARATORS_[comparator]

  satisfies version/SemanticVersion -> bool:
    return check.call version constraint-version

  to-string -> string:
    return "$comparator$constraint-version"

  stringify -> string:
    return to-string

  operator == other -> bool:
    if other is not SimpleConstraint: return false
    return comparator == other.comparator and constraint-version == other.constraint-version

  hash-code -> int:
    return comparator.hash-code * 31 + constraint-version.hash-code

CONSTRAINT-COMPARATORS_ ::= {
  ">=": :: | v c | v >= c,
  "<=": :: | v c | v <= c,
  "<": :: | v c | v < c,
  ">": :: | v c | v > c,
  "=": :: | v c | v == c,
  "!=": :: | v c | v != c
}

