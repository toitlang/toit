// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .framed-control show FramedChannel
import .uart-rig as rig
import .uart-stream as stream

/**
EC618 UART2 RX-ring contract test.

The ESP32 sends acknowledged bursts while this application deliberately reads only the separate UART1 control lane. Fitting bursts survive completely; an overflowing burst keeps an exact prefix, counts dropped newest bytes in `Port.errors`, and must not wedge the next receive.
*/

CONTROL-BAUD ::= 115200
CONTROL-TIMEOUT-MS ::= 15_000
BAUD ::= 921600
RING ::= 32768
SLACK ::= 512 + 32

main:
  control-owner := rig.ec618-uart 1 CONTROL-BAUD
  control := FramedChannel control-owner.port
  test-owner := rig.ec618-uart 2 BAUD
  test := test-owner.port
  failures := []

  try:
    stream.connect-control control

    // A no-reader burst: [send size, min survivors, max survivors].
    probe := : | send/int lo/int hi/int label/string |
      control.send "BAUD $BAUD"
      control.expect "READY $BAUD" --timeout-ms=CONTROL-TIMEOUT-MS
      stream.drain test
      errors-before := test.errors

      control.send "SEND $send"
      control.expect "READY-SEND $send" --timeout-ms=CONTROL-TIMEOUT-MS
      control.send "GO-SEND $send"
      // Waiting on UART1 does not consume UART2: the entire acknowledged burst
      // accumulates in its hardware FIFO/ring before the application drains it.
      control.expect "SENT $send" --timeout-ms=CONTROL-TIMEOUT-MS

      result := stream.drain-counted test
      count := result[0]
      crc-ok := result[1] == (stream.crc-of-stream count)
      errs := test.errors - errors-before
      counted := count + errs
      ok := lo <= count and count <= hi
          and crc-ok
          and (send <= hi ? errs == 0 : errs > 0)
          and counted <= send and counted >= send - 100
      print "uart2-ring-ec618: $label burst=$send survived=$count (want $lo..$hi) prefix-crc=$(crc-ok ? "ok" : "BAD") errors=$errs accounted=$counted/$send $(ok ? "ok" : "FAIL")"
      if not ok: failures.add label

    probe.call 4000        4000        4000               "small"
    probe.call 32000       32000       32000              "near-capacity"
    probe.call 40000       (RING - 1)  (RING - 1 + SLACK) "overflow"
    probe.call 4000        4000        4000               "post-overflow"

    test.baud-rate = BAUD
    probe.call 4000        4000        4000               "post-set-baud"

    test-owner.close
    test-owner = rig.ec618-uart 2 BAUD
    test = test-owner.port
    probe.call 4000        4000        4000               "post-reopen"

    control.send "Q"
    control.expect "BYE" --timeout-ms=CONTROL-TIMEOUT-MS
  finally:
    test-owner.close
    control-owner.close

  if not failures.is-empty:
    print "uart2-ring-ec618: FAIL $failures"
    throw "UART2 ring contract broken: $failures"
  print "uart2-ring-ec618: PASS 32KiB ring, counted drop-newest, RX survives overflow/set-baud/reopen"
