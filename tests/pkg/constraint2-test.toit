// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import ...tools.pkg.semantic-version
import ...tools.pkg.constraints

TESTS ::= [
  ["0", ">=0.0.0,<1.0.0"],
  ["1", ">=1.0.0,<2.0.0"],
  ["0.5", ">=0.5.0,<0.6.0"],
  ["1.5", ">=1.5.0,<1.6.0"],
  ["0.5.3", "=0.5.3"],
  ["1.5.3", "=1.5.3"],
  ["1.5.3-alpha", "=1.5.3-alpha"],
]

main:
  TESTS.do: | test/List |
    input := test[0]
    expected := test[1]

    constraint := Constraint.parse-range input
    simple-constraints := constraint.simple-constraints
    str := (simple-constraints.map: it.stringify).join ","
    expect-equals expected str
