// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.pkg.semantic-version
import ...tools.pkg.constraints

check-constraint v/string c/string:
  expect --message="$v $c"
      (Constraint.parse c).satisfies
          SemanticVersion.parse v

check-not-constraint v/string c/string:
  expect-not --message="not $v$c"
      (Constraint.parse c).satisfies
          SemanticVersion.parse v

check-to-string source/string expected/string:
  constraint := Constraint.parse source
  expect-equals expected constraint.to-string
  // The string must describe the same range.
  expect-equals constraint (Constraint.parse expected)

main:
  check-constraint "2.1.2" "^2.1.1"
  check-constraint "2.1.1" "^2.1.1"
  check-constraint "2.9.1" "^2.1.1"

  check-constraint "2.1.2" "~2.1.1"
  check-constraint "2.1.6" "~2.1.1"

  check-constraint "2.1.2" ">=2.1.1"
  check-constraint "2.1.1" ">=2.1.1"
  check-constraint "3.1.1" ">=2.1.1"

  check-constraint "2.1.2" "<2.2.1"
  check-constraint "2.1.2" "<3.2.1"

  check-constraint "2.1.2" ">2.1.1"
  check-constraint "3.1.2" ">2.2.1"

  check-constraint "2.2.1" "<=2.2.1"
  check-constraint "1.2.1" "<=2.2.1"
  check-constraint "2.2.1" "=2.2.1"

  check-constraint "2.2.1" "2.2.1"
  check-constraint "5.2.1" "=5.2.1"

  check-constraint "2.0.0-alpha.121.31+pgk-in-toit.95591318" "^2.0.0-alpha.79"

  check-not-constraint "2.1.0" "^2.1.1"
  check-not-constraint "3.1.0" "^2.1.1"
  check-not-constraint "2.2.0" "~2.1.1"
  check-not-constraint "3.1.0" "=2.1.1"
  check-not-constraint "3.1.0" "3.1.1"
  check-not-constraint "2.1.1-alpha" "^2.1.1"

  check-constraint "2.1.1" ">2.1.0, <2.1.2"
  check-constraint "3.1.1" ">2.1.0, <4.0.0"
  check-constraint "2.1.0" ">=2.1.0, <4.0.0"
  check-constraint "4.0.0" ">=2.1.0, <=4.0.0"
  check-not-constraint "4.0.0" ">=2.1.0, <4.0.0"

  // For major=0, caret should only allow same minor version.
  check-constraint "0.1.0" "^0.1.0"
  check-constraint "0.1.5" "^0.1.0"
  check-constraint "0.1.5" "^0.1.5"
  check-constraint "0.1.6" "^0.1.5"
  check-not-constraint "0.2.0" "^0.1.0"
  check-not-constraint "0.1.5" "^0.1.6"
  check-not-constraint "0.2.0" "^0.1.6"
  check-not-constraint "0.1.0" "^0.0.0"
  check-constraint "0.1.0" ">=0.0.0,<1.0.0"
  check-constraint "0.9.0" ">=0.0.0,<1.0.0"
  check-not-constraint "1.0.0" ">=0.0.0,<1.0.0"

  check-to-string "^1.2.3" "^1.2.3"
  check-to-string "~1.2.3" "~1.2.3"
  check-to-string ">=1.0.0,<2.0.0" "^1.0.0"
  check-to-string "^2.0.0-alpha.79" "^2.0.0-alpha.79"
  check-to-string "^0.1.2" "^0.1.2"
  check-to-string "^0.0.3" "^0.0.3"
  // For major 0, caret and tilde are the same range.
  check-to-string "~0.1.2" "^0.1.2"
  check-to-string "~0.0.1" "^0.0.1"
  check-to-string ">=0.0.0,<1.0.0" ">=0.0.0,<1.0.0"
  check-to-string ">=0.1.2,<1.0.0" ">=0.1.2,<1.0.0"
  check-to-string ">=1.2.3,<3.0.0" ">=1.2.3,<3.0.0"
