// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo a b c d e f g h: return a + b + c + d + e + f + g + h

main:
  // While it's recommended to have meaningful indentation, the next
  // line can start anywhere. The `\n` is really completely ignored.
  expect-equals "foo"\
 "foo"

  expect-equals
      36
      foo 1 2 3 4 \
        5 6 7 8

  sum := 1 +\
    2 +\
    3 +\
    4 +\
    5
  expect-equals 15 sum

  // Note that there isn't any newline in the string itself.
  // The leading indentation stays.
  str := " $(%.3f\
    3.14)"
  expect-equals " 3.140" str

  // Escaped newlines count as whitespace.
  str = "   $(%.3f\
3.14)"
  expect-equals "   3.140" str

  str = "  $(\
 sum)"
  expect-equals "  15" str

  expect-equals 36
    foo\
1\
2\
3\
4\
5\
6\
7\
8
