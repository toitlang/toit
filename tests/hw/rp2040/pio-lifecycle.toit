// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import rp2040.pio
import system
import ..rp2350.pio-rp2350 as shared
import .pio-smoke as smoke

// No pins are configured or driven. Reuse the chip-independent API checks,
// then check RP2040's two PIO blocks and twelve DMA channels explicitly.
main:
  with-timeout --ms=60_000:
    // Repeated native-buffer returns must not undercount external memory when
    // the byte-array finalizers run, including after ownership consumption.
    16.repeat:
      smoke.main
      stats := system.process-stats --gc
      expect (0 <= stats[system.STATS-INDEX-ALLOCATED-MEMORY] <=
          stats[system.STATS-INDEX-RESERVED-MEMORY])
    shared.allocating-read-test
    shared.heap-buffer-test
    shared.cancellation-tests
    shared.waiter-close-test
    shared.concurrent-reclaim-test
    shared.orphan-test
    shared.irq-tests
    10.repeat:
      allocation-test
      system.process-stats --gc
  print "pio-lifecycle-rp2040: PASS"

allocation-test:
  program := pio.Program (List 32: 0xa042)
  machines := []
  try:
    8.repeat: machines.add (pio.StateMachine program)
    expect-throw "ALREADY_IN_USE": pio.StateMachine program
    // Machines remain paused: TX stalls after filling its FIFO and RX has
    // nothing to receive, keeping all twelve channels allocated concurrently.
    6.repeat: | i/int |
      machine/pio.StateMachine := machines[i]
      machine.submit-write (ByteArray.external 64) --no-copy
      machine.submit-read (ByteArray.external 64) --no-copy
    rejected := ByteArray.external 64
    seventh/pio.StateMachine := machines[6]
    expect-throw "ALREADY_IN_USE": seventh.submit-read rejected --no-copy
    expect-equals 64 rejected.size
    system.process-stats --gc
  finally:
    machines.do: it.close
