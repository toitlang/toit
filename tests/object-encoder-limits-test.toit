// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The object encoder (the encode-object and encode-error primitives) must
// terminate on collections that contain themselves, and must not return
// more bytes than fit its buffer.

main:
  test-cycles
  test-overflow

test-cycles:
  list := []
  list.add list
  expect-not-null (encode_ list)
  expect-not-null (encode-error "FOO" list)

  array := Array_ 1
  array[0] = array
  expect-not-null (encode_ array)

  // Ten references to itself: without a bound this visits 10^n elements.
  wide := []
  10.repeat: wide.add wide
  catch: encode_ wide
  encode-error "FOO" wide

/** Calls the encode-error primitive; null if it fails. */
encode-error type message -> ByteArray?:
  #primitive.core.encode-error:
    return null

test-overflow:
  // About 250KB of output; the encode-object buffer is 1KB.
  s := "x" * 250
  big := List 10: List 10: List 10: s
  expect-throw "OUT_OF_BOUNDS": encode_ big
  // The error encoder has a larger buffer, but not large enough.
  expect-null (encode-error "FOO" big)
