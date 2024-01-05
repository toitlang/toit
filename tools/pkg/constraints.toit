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

class Constraint:
  constraints/List
  source/string

  constructor .source/string:
    parsed := (ConstraintParser source).constraints
    constraints = []
    parsed.do: | constraint/ConstraintParseResult |
      version := SemanticVersion.from-parse-result constraint.semantic-version
      if constraint.prefix == "^":
        constraints.add (SimpleConstraint ">=" version)
        constraints.add (SimpleConstraint "<" (SemanticVersion --major=version.major + 1))
      else if constraint.prefix == "~" or constraint.prefix == "~>":
        constraints.add (SimpleConstraint ">=" version)
        constraints.add (SimpleConstraint "<" (SemanticVersion --major=version.major --minor=version.minor + 1))
      else if constraint.prefix == "":
        constraints.add (SimpleConstraint "=" version)
      else:
        constraints.add (SimpleConstraint constraint.prefix version)

  satisfies version/SemanticVersion -> bool:
    constraints.do:
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

