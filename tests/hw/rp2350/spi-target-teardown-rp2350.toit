// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import expect show expect-equals
import spi
import system
import system.storage
import .spi-target-contract-rp2350 as contract

BUCKET ::= "toit-rp2350-test/spi-teardown"

/**
Tests process exit with both SPI blocks armed and four DMA channels owned.

Run with the ESP32 peer stopped and its SPI pins released. The constructors
  arm the hardware before returning. Exiting bypasses Toit finally blocks and
  leaves native process cleanup responsible for stopping DMA before freeing
  its buffers. The parent waits for child termination, then runs the SPI target
  contract in the same VM to verify controller, GPIO, DMA and handler reuse.
*/
main:
  bucket := storage.Bucket.open --ram BUCKET
  try:
    3.repeat:
      bucket.remove "armed"
      child := spawn:: leave-targets-armed
      with-timeout --ms=10_000:
        while true:
          error := catch: child.priority
          if error:
            expect-equals "INVALID_ARGUMENT" error
            break
          sleep --ms=1
      expect-equals 2 bucket["armed"]
      system.process-stats --gc
      contract.main
    print "spi-target-teardown-rp2350: PASS three child exits and same-VM resource reuse"
  finally:
    bucket.remove "armed"
    bucket.close

leave-targets-armed -> none:
  targets := [
    spi.BufferTarget #[1, 2, 3]
        --mosi=4
        --miso=7
        --clock=6
        --cs=5
        --mode=1
        --dma,
    spi.BufferTarget #[4, 5, 6]
        --mosi=8
        --miso=11
        --clock=10
        --cs=9
        --mode=3
        --dma,
  ]
  // Keep both resource owners reachable until the explicit process exit.
  bucket := storage.Bucket.open --ram BUCKET
  bucket["armed"] = targets.size
  print "spi-target-teardown-rp2350: exiting with $(targets.size) armed DMA targets"
  exit targets.size - 2
