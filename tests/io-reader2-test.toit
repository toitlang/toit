// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import .io-utils

test-read-lines input/List expected-with-newlines/List:
  expected-without-newlines := expected-with-newlines.map: | line/string |
    if line.ends-with "\r\n": line.trim --right "\r\n"
    else if line.ends-with "\n": line.trim --right "\n"
    else: line

  r := TestReader input
  expected-without-newlines.do:
    expect-equals it r.read-line
  expect-null r.read-line

  r = TestReader input
  expected-with-newlines.do:
    expect-equals it (r.read-line --keep-newline)
  expect-null (r.read-line --keep-newline)

  r = TestReader input
  expect-equals expected-without-newlines r.read-lines
  expect-null r.read-line

  r = TestReader input
  expect-equals expected-with-newlines (r.read-lines --keep-newlines)
  expect-null (r.read-line --keep-newline)

  lines := []
  r = TestReader input
  r.do --lines: lines.add it
  expect-equals expected-without-newlines lines

  lines = []
  r = TestReader input
  r.do --lines --keep-newlines: lines.add it
  expect-equals expected-with-newlines lines

main:
  test-read-lines [""] []
  test-read-lines ["foo\n", "bar\n"] ["foo\n", "bar\n"]
  test-read-lines ["f", "o", "", "o", "\n", "", "b", "", "a", "r", "\n"] ["foo\n", "bar\n"]
  test-read-lines ["foo\r\n", "bar\r\n"] ["foo\r\n", "bar\r\n"]
  test-read-lines ["f", "o", "", "o", "\r", "\n", "", "b", "", "a", "r", "\r", "\n"] ["foo\r\n", "bar\r\n"]
  test-read-lines ["f", "o", "", "o", "\n", "", "b", "", "a", "r", "\n"] ["foo\n", "bar\n"]
  test-read-lines ["foo\r\n", "bar"] ["foo\r\n", "bar"]
  test-read-lines ["f", "o", "", "o", "\r", "\n", "", "b", "", "a", "r"] ["foo\r\n", "bar"]
  test-read-lines ["foo\r\nbar"] ["foo\r\n", "bar"]
  test-read-lines ["foo\r\n", "bar"] ["foo\r\n", "bar"]
  test-read-lines ["f", "o", "", "o", "\r", "\n", "", "b", "", "a", "r"] ["foo\r\n", "bar"]
  test-read-lines ["foo\r\nbar"] ["foo\r\n", "bar"]
