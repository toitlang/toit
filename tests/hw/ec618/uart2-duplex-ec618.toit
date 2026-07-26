// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor

import .framed-control show FramedChannel
import .uart-rig as rig
import .uart-stream as stream

/**
EC618 UART2 full-duplex stress test.

Both peers start receiving before an acknowledged go command releases their simultaneous deterministic streams. The ESP32 returns its byte count and checksum over the framed UART1 control lane, so one test verdict covers both sides rather than relying on a separately inspected console.
*/

BAUDS ::= [921600, 2000000, 3000000]
CONTROL-BAUD ::= 115200
CONTROL-TIMEOUT-MS ::= 35_000
TOTAL ::= 256 * 1024

main:
  control-owner := rig.ec618-uart 1 CONTROL-BAUD
  control := FramedChannel control-owner.port
  test-owner := rig.ec618-uart 2 BAUDS[0]
  test := test-owner.port
  failures := []
  expected := stream.crc-of-stream TOTAL

  try:
    stream.connect-control control

    BAUDS.do: | baud/int |
      test.baud-rate = baud
      control.send "BAUD $baud"
      control.expect "READY $baud" --timeout-ms=CONTROL-TIMEOUT-MS

      errors-before := test.errors
      control.send "DUPLEX $TOTAL"
      control.expect "READY-DUPLEX $TOTAL" --timeout-ms=CONTROL-TIMEOUT-MS
      received := monitor.Latch
      task:: received.set (stream.recv-stream test TOTAL)
      control.send "GO-DUPLEX $TOTAL"
      stream.send-stream test TOTAL
      got := received.get
      peer-report := control.receive --timeout-ms=CONTROL-TIMEOUT-MS
      peer := stream.parse-report peer-report "DUPLEXED"

      errs := test.errors - errors-before
      count := got[1]
      local-ok := got[0] == expected and count == TOTAL and errs == 0
      peer-ok := peer and peer[0] == expected and peer[1] == TOTAL
      detail := "count=$count errs=$errs max-read=$got[2]"
      print "uart2-duplex-ec618: baud=$baud local=$(local-ok ? "ok" : "FAIL") peer=$(peer-ok ? "ok" : "FAIL ($peer-report)") ($detail)"
      if not local-ok: failures.add "rx@$baud"
      if not peer-ok: failures.add "tx@$baud"

    control.send "Q"
    control.expect "BYE" --timeout-ms=CONTROL-TIMEOUT-MS
  finally:
    test-owner.close
    control-owner.close

  if not failures.is-empty:
    print "uart2-duplex-ec618: FAIL $failures"
    throw "UART2 duplex failed: $failures"
  print "uart2-duplex-ec618: PASS $TOTAL bytes each way simultaneously at $BAUDS"
