// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import crypto.sha256 as crypto
import crypto.sha1 as crypto
import crypto.adler32 as crypto
import crypto.aes as crypto
import system

limit := 10
count := 0

should-never-die ::= List

provoke-finalization-processing:
  current-count := system.gc-count
  while system.gc-count <= current-count: List 100
  sleep --ms=10  // Allow finalization to run.

main:
  test-finalizers

  test-add-finalizer
  test-remove-finalizer

  test-multiple-add-remove

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
    "ALREADY_EXISTS"
    : add-finalizer object:: null

  expect-throw
    "WRONG_OBJECT_TYPE"
    : add-finalizer 5:: null

  expect-throw
    "WRONG_OBJECT_TYPE"
    : add-finalizer "Horse":: null

  expect-throw
    "WRONG_OBJECT_TYPE"
    : add-finalizer (ByteArray 5):: null

  // Can't add a finalizer to an object that already has one.
  // Large strings become external and need a VM finalizer.
  expect-throw "WRONG_OBJECT_TYPE":
    add-finalizer make-huge-string:: null

make-huge-string -> string:
  return "x" * 35000

test-remove-finalizer:
  object ::= List
  add-finalizer object:: null
  expect
    remove-finalizer object

  expect-not
    remove-finalizer List

test-multiple-add-remove:
  object/List? := List

  first-called := false
  second-called := false

  add-finalizer object::
    first-called = true

  remove-finalizer object

  add-finalizer object::
    second-called = true

  object = null  // Now it can be GCed.

  provoke-finalization-processing

  expect (not first-called)  // This one was removed - should not be called.
  expect second-called
