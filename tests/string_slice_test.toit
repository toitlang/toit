// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Tests that the hash-code field of string slices works.
// At some point the compiler wasn't allocating enough space and
//   allocating a new object would overwrite the hash code of string
//   slices.

main:
  str := "-In ancient times cats were worshiped as gods; they have not forgotten this."
  expected_hash := (str.copy 1).hash_code
  slice := str[1..]
  hash := slice.hash_code
  slice2 := str[1..]
  expect_equals expected_hash hash
  expect_equals expected_hash slice.hash_code
  expect_equals expected_hash slice2.hash_code
  new_object := [1, 2]
  expect_equals expected_hash hash
  expect_equals expected_hash slice.hash_code
  expect_equals expected_hash slice2.hash_code
