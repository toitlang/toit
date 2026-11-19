// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system

// The finalizer bit in an object's header also marks the VM finalizer that
// frees the memory of an external byte array. remove-finalizer must not
// clear it, or the memory is never freed.

remove-finalizer object -> bool:
  #primitive.core.remove-finalizer

new-external size/int -> ByteArray:
  #primitive.core.byte-array-new-external

SIZE ::= 100_000
COUNT ::= 100

allocated-memory -> int:
  stats := system.process-stats --gc
  return stats[system.STATS-INDEX-ALLOCATED-MEMORY]

main:
  before := allocated-memory
  COUNT.repeat:
    bytes := new-external SIZE
    expect-equals SIZE bytes.size
    expect-not (remove-finalizer bytes)
  after := allocated-memory
  // Without the fix the memory of every array stays allocated.
  expect after - before < COUNT * SIZE / 2

  // Instances still have their finalizers removed.
  object := Object
  add-finalizer object:: throw "unreachable"
  expect (remove-finalizer object)
  expect-not (remove-finalizer object)
