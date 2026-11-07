// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import io
import io.stdio
import system

main:
  print "usb-stress: READY"
  blocks := io.LITTLE-ENDIAN.uint32 (stdio.stdin.read-bytes 4) 0
  expect (1 <= blocks <= 100_000)
  ticks := 0
  collector := task::
    while true:
      system.process-stats --gc
      ticks++
      sleep --ms=1
  try:
    blocks.repeat: | block/int |
      data := stdio.stdin.read-bytes 1031
      data.size.repeat: | i/int |
        expect-equals ((block + i) * 37 % 256) data[i]
      print "usb-stress: block $block"
    expect (ticks > 0)
    print "usb-stress: PASS $blocks blocks, $ticks collections"
    // Recovery must interrupt this read without consuming application input.
    stdio.stdin.read-byte
    throw "Unexpected application input during recovery request"
  finally:
    collector.cancel
