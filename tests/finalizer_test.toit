// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import crypto.sha256 as crypto
import crypto.sha1 as crypto
import crypto.adler32 as crypto
import crypto.aes as crypto

limit := 10
count := 0

should_never_die ::= List

provoke_finalization_processing:
  current_count := gc_count
  while gc_count <= current_count: List 100
  sleep --ms=10  // Allow finalization to run.

main:
  test_finalizers

  test_add_finalizer
  test_remove_finalizer

test_finalizers:
  add_finalizer should_never_die:: throw "Wrong object to declare dead"
  limit.repeat: add_finalizer List:: count++
  provoke_finalization_processing
  expect_equals limit count

test_add_finalizer:
  object := List
  expect_equals
    object
    add_finalizer object null

  expect_throw
    "OUT_OF_BOUNDS"
    : add_finalizer object:: null

  expect_throw
    "WRONG_OBJECT_TYPE"
    : add_finalizer 5:: null

  byte_array ::= ByteArray 0
  expect_equals
    byte_array
    add_finalizer byte_array:: null

  expect_no_throw:
    add_finalizer make_huge_string:: null

make_huge_string -> string:
  return "x" * 4097

test_remove_finalizer:
  object ::= List
  add_finalizer object:: null
  expect
    remove_finalizer object

  string_obj ::= "test"
  add_finalizer string_obj:: null
  expect
    remove_finalizer string_obj

  expect_not
    remove_finalizer List
