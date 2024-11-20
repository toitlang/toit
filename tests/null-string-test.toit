// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.directory
import host.file

main:
  null-string := "foo\0bar"
  test: directory.mkdir null-string
  test: directory.mkdtemp null-string
  test: file.is-directory null-string
  test: file.is-file null-string
  e := catch: file.Stream.for-read null-string
  expect (e.starts-with "INVALID_ARGUMENT")
  e = catch: file.Stream.for-write null-string
  expect (e.starts-with "INVALID_ARGUMENT")

  // However, print works.
  print null-string
  print-on-stderr_ null-string

test [block]:
  expect-throw "INVALID_ARGUMENT" block
