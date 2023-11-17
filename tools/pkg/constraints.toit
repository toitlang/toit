import .semantic-version
import .parsers.constraint-parser

class Constraint:
  constraints/List

  constructor source/string:
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

class SimpleConstraint:
  comparator/string
  constraint-version/SemanticVersion
  check/Lambda
  constructor .comparator/string .constraint-version:
    this.check = CONSTRAINT-COMPARATORS_[comparator]

  satisfies version/SemanticVersion -> bool:
//    print "$version$comparator$constraint-version: $(check.call version constraint-version)"
    return check.call version constraint-version


CONSTRAINT-COMPARATORS_ ::= {
  ">=": :: | v c | v >= c,
  "<=": :: | v c | v <= c,
  "<": :: | v c | v < c,
  ">": :: | v c | v > c,
  "=": :: | v c | v == c,
  "!=": :: | v c | v != c
}

