// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

TESTS ::= [
  [0.0, "0.0"],
  [0.1, "0.1"],
  [0.0001, "0.0001"],
  [0.0000000001, "1e-10"],
  [12332.0, "12332.0"],
  [123434343242432.0, "123434343242432.0"],
  [100000000000000000000000.0, "1e23"],
  [0.2, "0.2"],
  [1.2, "1.2"],
  [12.3, "12.3"],
  [123.4, "123.4"],
  [1234.5, "1234.5"],
  [12345.6, "12345.6"],
  [123456.7, "123456.7"],
  [1234567.8, "1234567.8"],
  [12345678.9, "12345678.9"],
  [1.23, "1.23"],
  [1.234, "1.234"],
  [1.2345, "1.2345"],
  [1.23456, "1.23456"],
  [1.234567, "1.234567"],
  [1.2345678, "1.2345678"],
  [float.INFINITY, "inf"],
  [float.NAN, "nan"],
  [1.23456e78, "1.23456e78"],
  [1.23456e-78, "1.23456e-78"],
]

main:
  TESTS.do: | test |
    value := test[0]
    expected := test[1]
    result := value.to-string
    expect-equals expected result

    value = -value
    if value == value:  // Not NaN.
      expected = "-" + expected
    result = value.to-string
    expect-equals expected result
