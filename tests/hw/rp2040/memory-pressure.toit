// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system
import system.storage
import ..rp2350.memory-pressure-rp2350 as shared
import ...cross-process-gc-test as collections
import .pio-smoke as pio-test

main:
  system.serial-print-heap-report "before memory-pressure test"
  stats := system.process-stats
  free := stats[system.STATS-INDEX-SYSTEM-FREE-MEMORY]
  largest := stats[system.STATS-INDEX-SYSTEM-LARGEST-FREE]
  expect (4096 <= largest <= free < 264 * 1024)
  shared.main
  5.repeat:
    collections.allocate-too-much
    system.process-stats --gc
    // Confirm native allocations and DMA work after the failed allocation.
    pio-test.main
    // Exercise a different container while recovering from app memory pressure.
    bucket := storage.Bucket.open --ram "toit-rp2040-test/memory"
    try:
      bucket["alive"] = 1234
      expect-equals 1234 bucket["alive"]
      bucket.remove "alive"
    finally:
      bucket.close
  system.serial-print-heap-report "after memory-pressure test"
  print "memory-pressure-rp2040: PASS"
