// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import io.stdio
import system

main:
  print "stdio-rp2040: READY"
  expect-equals "update\r\nhello\n" (stdio.stdin.read-bytes 14).to-string
  ticks := 0
  collector := task::
    while true:
      system.process-stats --gc
      ticks++
      sleep --ms=1
  try:
    32.repeat: | block/int |
      data := stdio.stdin.read-bytes 1027
      data.size.repeat: | i/int |
        expect-equals ((block * 1027 + i) * 37 % 256) data[i]
      print "stdio-rp2040: block $block"
    expect (ticks > 0)
    print "stdio-rp2040: PASS binary input, GC, timers and update text"
    // The host must still be able to request recovery with this read pending.
    stdio.stdin.read-byte
    throw "Unexpected application input during recovery request"
  finally:
    collector.cancel
