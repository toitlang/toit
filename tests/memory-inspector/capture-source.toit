// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

class Node:
  value/any
  next/Node?
  constructor .value .next:

class Resource:

retained-nodes/Node? := null
big-buffer/ByteArray? := null
resource/Resource? := null

build-list count/int -> Node?:
  node/Node? := null
  count.repeat: node = Node "node $it" node
  return node

// Creates a node that is only reachable through a finalizer.
register-finalizer id/int -> none:
  // Not a literal, so the string is on the heap.
  held := Node "held by finalizer $id" null
  resource = Resource
  add-finalizer resource:: print held.value

main:
  retained-nodes = build-list 500
  // Garbage: nothing references these nodes after the call, but a GC may
  // already have collected them.
  build-list 100
  big-buffer = ByteArray 20_000
  register-finalizer 1
  system.capture-memory --reason="first"
