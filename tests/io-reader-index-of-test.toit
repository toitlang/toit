// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import .io-utils

main:
  test "foobarX"
  test "Xfoobar"
  test "fooXbar"
  test "foobar"
  test ""

test input/string:
  expected := input.index-of "X"
  2.repeat:
    should-split := it == 1
    chunks := should-split
        ? input.split ""
        : [input]

    2.repeat:
      test-to := it == 1
      reader := TestReader chunks
      if not test-to:
        expect-equals expected (reader.index-of 'X')
      else:
        (input.size + 1).repeat: | to/int |
          pos := reader.index-of 'X' --to=to
          if expected >= 0 and to >= (expected + 1):
            expect-equals expected pos
          else:
            expect-equals -1 pos
