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
  [false, true].do: | should-split/bool |
    chunks := should-split
        ? input.split ""
        : [input]

    [false, true].do: | test-to/bool |
      [true, false].do: | test-buffered/bool |
        if not test-to:
          expect-equals expected ((reader chunks test-buffered).index-of 'X')
          if expected >= 0:
            expect-equals expected ((reader chunks test-buffered).index-of 'X' --throw-if-absent)
          else:
            expect-throw io.Reader.UNEXPECTED_END_OF_READER:
              (reader chunks test-buffered).index-of 'X' --throw-if-absent
        else:
          (input.size + 1).repeat: | to/int |
            pos := (reader chunks test-buffered).index-of 'X' --to=to
            if expected >= 0 and to >= (expected + 1):
              expect-equals expected pos
              expect-equals expected ((reader chunks test-buffered).index-of 'X' --to=to --throw-if-absent)
            else:
              expect-equals -1 pos
              expect-throw io.Reader.UNEXPECTED_END_OF_READER:
                (reader chunks test-buffered).index-of 'X' --to=to --throw-if-absent

reader chunks/List buffered/bool -> io.Reader:
  result := TestReader chunks
  if buffered: result.buffer-all
  return result
