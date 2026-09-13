// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import ...format-test as formats

main:
  // Exercise the actual base libc, including both stack and heap buffers.
  formats.main
  expect-equals "-9223372036854775808" (string.format "d" int.MIN)
  expect-equals "0.000" (string.format ".3f" 0.0)
  expect-equals "-0.000" (string.format ".3f" -0.0)
  expect-equals "12.340" (string.format ".3f" 12.34)
  expect-equals "-12.340" (string.format ".3f" -12.34)
  expect-equals "2.0" (string.format ".0f" 2.5)
  expect-equals "4.0" (string.format ".0f" 3.5)
  expect-equals "-2.0" (string.format ".0f" -2.5)
  expect-equals "nan" (string.format ".3f" float.NAN)
  expect-equals "inf" (string.format ".3f" float.INFINITY)
  expect-equals "-inf" (string.format ".3f" -float.INFINITY)

  zeros := ""
  64.repeat: zeros += "0"
  expect-equals "0.$zeros" (string.format ".64f" (float.parse "5e-324"))
  expect-equals "1.25$(zeros[..62])" (string.format ".64f" 1.25)
  expect-equals "12.3399999999999998578914528479799628257751464843750000000000000000"
      string.format ".64f" 12.34

  // The largest finite double needs a heap buffer even at zero precision.
  largest := float.parse "1.7976931348623157e308"
  integer := "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368"
  expect-equals "$integer.0" (string.format ".0f" largest)
  expect-equals "-$integer.$zeros" (string.format ".64f" -largest)
  100.repeat:
    expect-equals "12.340" (string.format ".3f" 12.34)
    expect-equals "1.25$(zeros[..62])" (string.format ".64f" 1.25)
  print "float-format-ec618: PASS"
