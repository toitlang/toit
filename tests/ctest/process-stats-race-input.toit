// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

// Spawns processes that allocate (they scavenge all the time and promote
// objects to old space) while this process reads their statistics
// (system.process-stats) as fast as it can: process-stats-race-test runs it
// in a VM with several scheduler threads, so that the reads overlap the
// children's collections on other threads.

CHILDREN ::= 3
RING ::= 64

main:
  gid := (system.process-stats)[system.STATS-INDEX-GROUP-ID]
  deadline := Time.monotonic-us + 2_000_000
  children := List CHILDREN: spawn:: churn deadline
  answered := 0
  while Time.monotonic-us < deadline:
    children.do: | child/Process |
      stats := system.process-stats gid child.id
      if stats:
        answered++
        if stats[system.STATS-INDEX-PROCESS-ID] != child.id: throw "WRONG_PROCESS"
        if stats[system.STATS-INDEX-ALLOCATED-MEMORY] < 0: throw "NEGATIVE_ALLOCATED"
        if stats[system.STATS-INDEX-RESERVED-MEMORY] < 0: throw "NEGATIVE_RESERVED"
  if answered == 0: throw "NO_ANSWER"

churn deadline/int -> none:
  ring := List RING
  i := 0
  while Time.monotonic-us < deadline:
    // Short-lived garbage (scavenges) and a ring of survivors (promotion).
    garbage := List 16: ByteArray 48
    ring[i % RING] = [garbage[0], "$i"]
    i++
