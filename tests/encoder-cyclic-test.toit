// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.ubjson
import expect show *

// The VM encodes objects (for example the message of an exception) with a
// bounded nesting depth. Cyclic or very deeply nested collections used to make
// the encoder recurse until the native stack overflowed.

encode-object_ o -> ByteArray?:
  #primitive.core.encode-object:
    return null

encode-error_ type message -> ByteArray?:
  #primitive.core.encode-error:
    return null

main:
  cyclic-array := Array_ 1
  cyclic-array[0] = cyclic-array
  test cyclic-array

  cyclic-list := [null]
  cyclic-list[0] = cyclic-list
  test cyclic-list

  deep := null
  10000.repeat:
    next := Array_ 1
    next[0] = deep
    deep = next
  test deep

  deep-list := null
  10000.repeat: deep-list = [deep-list]
  test deep-list

  // A wide cyclic array would produce an exponential amount of output. The
  // encoding is allowed to fail, but must not crash or hang.
  wide := Array_ 10
  wide.size.repeat: wide[it] = wide
  encode-object_ wide
  encode-error_ "X" wide

  print "survived"

test o:
  object-bytes := encode-object_ o
  expect-not-null object-bytes
  // The header is ['X', sdk-version, vm-model, uuid, payload].
  decoded := ubjson.decode object-bytes
  expect-equals 'X' decoded[0]
  check-truncated decoded[4]

  error-bytes := encode-error_ "X" o
  expect-not-null error-bytes
  // The payload is ['E', type, message, stack].
  decoded = ubjson.decode error-bytes
  expect-equals 'X' decoded[0]
  error := decoded[4]
  expect-equals 'E' error[0]
  expect-equals "X" error[1]
  check-truncated error[2]

/**
Checks that the encoding of a nested array or list is truncated after a
  few levels, with the innermost collection encoded as an opaque instance.
*/
check-truncated encoded:
  depth := 0
  while true:
    tag := encoded[0]
    if tag == 'I': break
    expect (tag == 'A' or tag == 'L')
    expect-equals 1 encoded[1]  // The size of the collection.
    elements := encoded[2]
    expect-equals 1 elements.size
    encoded = elements[0]
    depth++
  expect 0 < depth < 100
