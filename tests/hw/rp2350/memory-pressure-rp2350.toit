// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system

main:
  sleep --ms=2000
  print "memory-pressure-rp2350: starting"
  retained := List 64: ByteArray 513 --initial=it
  before := system.gc-count
  20.repeat:
    error := catch: ByteArray (1 << 20)
    expect (error == "MALLOC_FAILED" or error == "ALLOCATION_FAILED")
    retained.size.repeat: | i/int |
      expect-equals i retained[i][0]
      expect-equals i retained[i][512]
    system.process-stats --gc
    // Check that timers and other containers can still make progress after
    // each failed native allocation and GC retry sequence.
    sleep --ms=1
  expect (system.gc-count > before)
  print "memory-pressure-rp2350: PASS rejected oversized allocations, retained data, GC, and timers"
