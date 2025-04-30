// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import reader show BufferedReader Reader

class TestReader implements Reader:
  index_ := 0
  strings_ := ?

  constructor .strings_:

  read:
    if index_ >= strings_.size: return null
    return strings_[index_++].to-byte-array

main:
  r := BufferedReader (TestReader ["foo\n", "bar\n"])  // NO-WARN
  expect-equals "foo" r.read-line
  expect-equals "bar" r.read-line
  expect-equals null r.read-line
  expect-equals null r.read-line

  r = BufferedReader (TestReader ["f", "o", "", "o", "\n", "", "b", "", "a", "r", "\n"])  // NO-WARN
  expect-equals "foo" r.read-line
  expect-equals "bar" r.read-line
  expect-equals null r.read-line
  expect-equals null r.read-line

  r = BufferedReader (TestReader ["foo\r\n", "bar\r\n"])  // NO-WARN
  expect-equals "foo" r.read-line
  expect-equals "bar" r.read-line
  expect-equals null r.read-line
  expect-equals null r.read-line

  r = BufferedReader (TestReader ["f", "o", "", "o", "\r", "\n", "", "b", "", "a", "r", "\r", "\n"])  // NO-WARN
  expect-equals "foo" r.read-line
  expect-equals "bar" r.read-line
  expect-equals null r.read-line
  expect-equals null r.read-line

  r = BufferedReader (TestReader ["foo\n", "bar\n"])  // NO-WARN
  expect-equals "foo" r.read-line
  expect-equals "bar" r.read-line
  expect-equals null r.read-line
  expect-equals null r.read-line

  r = BufferedReader (TestReader ["f", "o", "", "o", "\n", "", "b", "", "a", "r", "\n"])  // NO-WARN
  expect-equals "foo" r.read-line
  expect-equals "bar" r.read-line
  expect-equals null r.read-line
  expect-equals null r.read-line

  r = BufferedReader (TestReader ["foo\r\n", "bar"])  // NO-WARN
  expect-equals "foo" r.read-line
  expect-equals "bar" r.read-line
  expect-equals null r.read-line
  expect-equals null r.read-line

  r = BufferedReader (TestReader ["f", "o", "", "o", "\r", "\n", "", "b", "", "a", "r"])  // NO-WARN
  expect-equals "foo" r.read-line
  expect-equals "bar" r.read-line
  expect-equals null r.read-line
  expect-equals null r.read-line

  r = BufferedReader (TestReader ["foo\r\n", "bar"])  // NO-WARN
  expect-equals "foo" r.read-line
  expect-equals "bar" (r.read-string 3)
  expect-equals null r.read-line
  expect-equals null r.read-line

  r = BufferedReader (TestReader ["f", "o", "", "o", "\r", "\n", "", "b", "", "a", "r"])  // NO-WARN
  expect-equals "foo" r.read-line
  expect-equals "bar" (r.read-string 3)
  expect-equals null r.read-line
  expect-equals null r.read-line

  r = BufferedReader (TestReader ["foo\r\nbar"])  // NO-WARN
  expect-equals "foo" r.read-line
  expect-equals "bar" (r.read-string 3)
  expect-equals null r.read-line
  expect-equals null r.read-line
