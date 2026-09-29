// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

class Node:
  value/any
  next/Node?
  constructor .value .next:

nodes/Node? := null
buffer/ByteArray? := null

main:
  300.repeat: nodes = Node "node $it" nodes
  // Big enough to be allocated outside the Toit heap.
  buffer = ByteArray 20_000
  print "MEMORY-CAPTURE-READY"
  system.capture-memory --reason="qemu"
  print "MEMORY-CAPTURE-DONE"
