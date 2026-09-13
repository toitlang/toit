// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Regression test for old-space compaction: when a destination chunk is
// abandoned right after a chunk switch, the destination address is biased
// below the chunk start to compensate for the tail of an object moved to the
// previous chunk. That biased address must not become the abandoned chunk's
// compaction top, and the bias must carry over to the next chunk.
//
// Layout (64-bit host, 32K chunks, 256-byte lines): [A][E][C] contiguous in
// old space, where E + C exceed one chunk, C starts in the line that holds the
// tail of A, and A's end offset within that line is in (0, 0x70).

import expect show *
import system

fill ba/ByteArray value/int -> ByteArray:
  ba.fill value
  return ba

check ba/ByteArray value/int:
  ba.size.repeat: expect-equals value ba[it]

run k/int:
  filler/List? := List 700
  700.repeat: filler[it] = ByteArray 1000
  200.repeat: ByteArray 1000  // Garbage; drives scavenges that promote filler.
  keep := List 7
  keep[0] = fill (ByteArray 32240 + 8 * k) 10   // A1.
  keep[1] = fill (ByteArray 128) 11             // E1.
  keep[2] = fill (ByteArray 32656) 12           // C1: goes to old space directly.
  keep[3] = fill (ByteArray 32240) 13           // A2: scavenge promotes A1, E1.
  keep[4] = fill (ByteArray 128) 14             // E2.
  keep[5] = fill (ByteArray 32656) 15           // C2: old space, right after E1.
  keep[6] = fill (ByteArray 32240) 16           // A3: promotes A2, E2.
  filler = null
  system.process-stats --gc
  7.repeat: check keep[it] 10 + it
  3.repeat:
    300.repeat: ByteArray 1000
    system.process-stats --gc
    7.repeat: check keep[it] 10 + it

main:
  if system.platform == system.PLATFORM-FREERTOS: return
  32.repeat:
    run it
    // Return the heap to a small, compacted state before the next layout.
    system.process-stats --gc
    system.process-stats --gc
