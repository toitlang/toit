// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io

class TestReader extends io.Reader:
  index_ := 0
  strings_ := ?

  constructor .strings_:

  read_:
    if index_ >= strings_.size: return null
    return strings_[index_++].to-byte-array

  close_:

expect-end-throw [block]:
  expect-throw "UNEXPECTED_END_OF_READER": block.call

main:
  reader := TestReader ["a", "b", "c"]
  skipped := reader.skip-up-to 'b'
  expect-equals 2 skipped

  // Only 'c' left.
  skipped = reader.skip-up-to 'b'
  expect-equals 1 skipped

  skipped = reader.skip-up-to 'b'
  expect-equals 0 skipped

  reader = TestReader ["a", "b", "c"]
  skipped = reader.skip-up-to 'd'
  expect-equals 3 skipped

  reader = TestReader ["a", "b", "c"]
  expect-end-throw: reader.skip-up-to 'd' --throw-if-absent

  reader = TestReader ["abc"]
  skipped = reader.skip-up-to 'b'
  expect-equals 2 skipped

  // Only 'c' left.
  skipped = reader.skip-up-to 'b'
  expect-equals 1 skipped

  skipped = reader.skip-up-to 'b'
  expect-equals 0 skipped

  reader = TestReader ["aaaaa"]
  5.repeat:
    skipped = reader.skip-up-to 'a'
    expect-equals 1 skipped
  skipped = reader.skip-up-to 'a'
  expect-equals 0 skipped
