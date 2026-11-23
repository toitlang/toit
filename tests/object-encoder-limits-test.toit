// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.ubjson
import expect show *

// The object encoder (the encode-object and encode-error primitives) must
// terminate on collections that contain themselves, and must not return
// more bytes than fit its buffer.

main:
  test-cycles
  test-overflow
  test-string-cutoff

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

test-string-cutoff:
  ascii := "a" * 255
  expect-equals ascii (ubjson.decode (encode_ ascii)).last
  expect-equals "$ascii..." (ubjson.decode (encode_ (ascii + "b"))).last
  // The cutoff can fall on any continuation byte of a four-byte character.
  3.repeat: |i|
    prefix := "a" * (252 + i)
    message := prefix + "😹" + "b"
    expected := prefix + "..."
    expect-equals expected (ubjson.decode (encode_ message)).last
    error := (ubjson.decode (encode-error "FOO" message)).last
    expect-equals expected error[2]
