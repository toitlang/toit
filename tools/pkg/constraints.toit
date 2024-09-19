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

  constructor --.simple-constraints --.source:

  static parse source/string -> Constraint:
    parsed := (ConstraintParser source).constraints --consume-all
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

  stringify -> string:
    return source

class SimpleConstraint:
  comparator/string
  constraint-version/SemanticVersion
  check/Lambda
  constructor .comparator/string .constraint-version:
    this.check = CONSTRAINT-COMPARATORS_[comparator]

  satisfies version/SemanticVersion -> bool:
    return check.call version constraint-version

  stringify -> string:
    return "$comparator$constraint-version"

CONSTRAINT-COMPARATORS_ ::= {
  ">=": :: | v c | v >= c,
  "<=": :: | v c | v <= c,
  "<": :: | v c | v < c,
  ">": :: | v c | v > c,
  "=": :: | v c | v == c,
  "!=": :: | v c | v != c
}

