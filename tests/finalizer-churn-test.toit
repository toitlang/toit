// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import system

// Adding and removing a finalizer must not leave a node on the finalizer
// list each time: a loop that doesn't allocate (and thus never triggers a
// GC) grew the malloced list without bound, and the nodes stayed for as long
// as the object lived when it got a new finalizer before the next GC.

add-finalizer-primitive object lambda:
  #primitive.core.add-finalizer

remove-finalizer-primitive object -> bool:
  #primitive.core.remove-finalizer

ITERATIONS ::= 5_000_000

/// The resident set size of this VM in bytes, or null if unknown.
resident-bytes -> int?:
  if system.platform != system.PLATFORM-LINUX: return null
  stream := file.Stream.for-read "/proc/self/statm"
  fields := stream.in.read-all.to-string.trim.split " "
  stream.close
  return (int.parse fields[1]) * 4096

main:
  test-semantics
  test-churn

test-semantics:
  calls := 0
  object/Object? := Object
  add-finalizer-primitive object:: calls++
  expect (remove-finalizer-primitive object)
  expect-not (remove-finalizer-primitive object)
  // A new finalizer after the removal runs once when the object dies.
  add-finalizer-primitive object:: calls += 10
  expect-throw "ALREADY_EXISTS": add-finalizer-primitive object:: null
  object = null
  system.process-stats --gc
  // Finalizers run in the finalization task.
  sleep --ms=50
  expect-equals 10 calls

test-churn:
  object := Object
  lambda := :: null
  before := resident-bytes
  ITERATIONS.repeat:
    add-finalizer-primitive object lambda
    remove-finalizer-primitive object
  add-finalizer-primitive object lambda
  after := resident-bytes
  if before:
    // A node is about 40 bytes; without the fix the loop takes 200 MB.
    growth := after - before
    expect growth < 50_000_000
  expect (remove-finalizer-primitive object)
