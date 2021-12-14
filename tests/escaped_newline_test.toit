// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

foo a b c d e f g h: return a + b + c + d + e + f + g + h

main:
  // While it's recommended to have meaningful indentation, the next
  // line can start anywhere. The `\n` is really completely ignored.
  expect_equals "foo"\
 "foo"

  expect_equals
      36
      foo 1 2 3 4 \
        5 6 7 8

  sum := 1 +\
    2 +\
    3 +\
    4 +\
    5
  expect_equals 15 sum

  // Note that there isn't any newline in the string itself.
  // The leading indentation stays.
  str := " $(%.3f\
    3.14)"
  expect_equals " 3.140" str

  // Escaped newlines count as whitespace.
  str = "   $(%.3f\
3.14)"
  expect_equals "   3.140" str

  str = "  $(\
 sum)"
  expect_equals "  15" str

  expect_equals 36
    foo\
1\
2\
3\
4\
5\
6\
7\
8
