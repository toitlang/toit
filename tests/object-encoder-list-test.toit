// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The object encoder (the encode-object and encode-error primitives) encodes
// the first elements of a List_. The size and backing are ordinary instance
// fields; a list whose size isn't within its backing array must be encoded
// as a plain instance, without reading past the array.

main:
  valid := List_.private_ 4 2
  valid[0] = 1
  valid[1] = 2
  // The same list, encoded as a plain instance.
  plain := encode_ (List_.private_ 0 10)
  expect-not-equals plain (encode_ valid)
  expect-equals plain (encode_ (List_.private_ 1 100_000))

  list := List_.private_ 2 2
  list.size_ = -1
  expect-equals plain (encode_ list)
  list.size_ = "not a smi"
  expect-equals plain (encode_ list)
  list.size_ = 1 << 40
  expect-equals plain (encode_ list)

  // Also in the message of an error.
  error := encode-error_ "FOO" (List_.private_ 1 100_000)
  expect-not-null error
