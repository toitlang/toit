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

should-never-die ::= List

provoke-finalization-processing:
  current-count := gc-count
  while gc-count <= current-count: List 100
  sleep --ms=10  // Allow finalization to run.

main:
  test-finalizers

  test-add-finalizer
  test-remove-finalizer

  test-double-finalizer

test-double-finalizer:
  str := "x" * 35_000  // Big enough string that it is external.

  expect-throw "OUT_OF_BOUNDS":
    add-finalizer str::
      print "String is dead"

test-finalizers:
  add-finalizer should-never-die:: throw "Wrong object to declare dead"
  limit.repeat: add-finalizer List:: count++
  provoke-finalization-processing
  expect-equals limit count

test-add-finalizer:
  object := List
  expect-null
    add-finalizer object null

  expect-throw
    "OUT_OF_BOUNDS"
    : add-finalizer object:: null

  expect-throw
    "WRONG_OBJECT_TYPE"
    : add-finalizer 5:: null

  byte-array ::= ByteArray 0
  expect-null
    add-finalizer byte-array:: null

  expect-no-throw:
    add-finalizer make-huge-string:: null

make-huge-string -> string:
  return "x" * 4097

test-remove-finalizer:
  object ::= List
  add-finalizer object:: null
  expect
    remove-finalizer object

  string-obj ::= "test"
  add-finalizer string-obj:: null
  expect
    remove-finalizer string-obj

  expect-not
    remove-finalizer List
