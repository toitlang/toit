// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io

main:
  test-simple

test-simple:
  buffer := io.Buffer
  expect-equals 0 buffer.size
  expect-equals 0 buffer.processed

  empty := buffer.bytes
  expect empty.is-empty

  buffer.write "foobar"
  expect-equals 6 buffer.processed
  foobar := buffer.bytes
  expect-equals 6 foobar.size
  expect-equals "foobar" foobar.to-string

  backing := buffer.backing-array
  buffer.reserve backing.size
  // Must grow, since some bytes are already used in the backing store.
  expect buffer.backing-array.size > backing.size
  // Still has to have the same content.
  expect-equals "foobar" buffer.bytes.to-string

  buffer.clear
  expect-equals 0 buffer.size

  // Grow must fill the buffer with 0s, even though the original
  //   backing store was already filled with junk.
  buffer.grow-by 6
  zeros := buffer.bytes
  6.repeat: expect-equals 0 zeros[it]

  buffer.clear
  expect-equals 0 buffer.processed
  buffer.write foobar
  expect-equals "foobar" buffer.bytes.to-string

  written := buffer.try-write foobar 1 4
  expect-equals 3 written
  expect-equals "foobaroob" buffer.bytes.to-string

  buffer.reserve 100
  buffer.reserve 5
  expect buffer.backing-array.size > 105
