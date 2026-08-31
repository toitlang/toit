// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

import .framed-control show FramedChannel
import .uart-rig as rig
import .uart-stream as stream

/**
EC618 half of the UART2 sustained-throughput and leak test.

Each direction carries an independently generated deterministic stream, so
  the test does not depend on the peer echoing at full rate. A framed UART1
  control channel acknowledges every UART2 transition and reports the ESP32's
  byte count and CRC.
*/

BAUDS ::= [921600, 1500000, 2000000, 3000000, 4000000]
CONTROL-BAUD ::= 115200
CONTROL-TIMEOUT-MS ::= 35_000
TX-TOTAL ::= 256 * 1024
RX-TOTAL ::= 1024 * 1024
LEAK-LIMIT ::= 8192

main:
  print "uart2-bigdata-ec618: starting"
  control-owner := rig.ec618-uart 1 CONTROL-BAUD
  print "uart2-bigdata-ec618: UART1 control open"
  control := FramedChannel control-owner.port
  test-owner/rig.OwnedPort? := null
  failures := []
  expected-tx := stream.crc-of-stream TX-TOTAL
  expected-rx := stream.crc-of-stream RX-TOTAL
  baseline := (system.process-stats --gc)[system.STATS-INDEX-ALLOCATED-MEMORY]

  try:
    stream.connect-control control
    print "uart2-bigdata-ec618: helper ready"
    test-owner = rig.ec618-uart 2 BAUDS[0]
    test := test-owner.port
    print "uart2-bigdata-ec618: UART2 test open"

    BAUDS.do: | baud/int |
      test.baud-rate = baud
      control.send "BAUD $baud"
      control.expect "READY $baud" --timeout-ms=CONTROL-TIMEOUT-MS
      print "uart2-bigdata-ec618: baud=$baud ready"

      // EC618 TX: the ESP32 is ready before the first raw byte is written.
      control.send "RECEIVE $TX-TOTAL"
      control.expect "READY-RECEIVE $TX-TOTAL" --timeout-ms=CONTROL-TIMEOUT-MS
      print "uart2-bigdata-ec618: baud=$baud sending $TX-TOTAL"
      stream.send-stream test TX-TOTAL
      report := control.receive --timeout-ms=CONTROL-TIMEOUT-MS
      parsed := stream.parse-report report "RECEIVED"
      tx-ok := parsed and parsed[0] == expected-tx and parsed[1] == TX-TOTAL
      print "uart2-bigdata-ec618: baud=$baud TX $(tx-ok ? "ok" : "FAIL ($report)")"
      if not tx-ok: failures.add "tx@$baud"

      // EC618 RX: wait until both receivers are ready, then release the sender.
      errors-before := test.errors
      control.send "SEND $RX-TOTAL"
      control.expect "READY-SEND $RX-TOTAL" --timeout-ms=CONTROL-TIMEOUT-MS
      control.send "GO-SEND $RX-TOTAL"
      got := stream.recv-stream test RX-TOTAL
      control.expect "SENT $RX-TOTAL" --timeout-ms=CONTROL-TIMEOUT-MS
      errs := test.errors - errors-before
      rx-ok := got[0] == expected-rx and got[1] == RX-TOTAL and errs == 0
      detail := "max-read=$got[2] first-bad=$got[3] errs=$errs"
      print "uart2-bigdata-ec618: baud=$baud RX $(rx-ok ? "ok" : "FAIL") ($detail)"
      if not rx-ok: failures.add "rx@$baud"

    final := (system.process-stats --gc)[system.STATS-INDEX-ALLOCATED-MEMORY]
    leak := final - baseline
    moved := BAUDS.size * (TX-TOTAL + RX-TOTAL)
    print "uart2-bigdata-ec618: moved $moved bytes; heap baseline=$baseline final=$final delta=$leak"
    if leak > LEAK-LIMIT: failures.add "leak($leak)"

    control.send "Q"
    control.expect "BYE" --timeout-ms=CONTROL-TIMEOUT-MS
  finally:
    if test-owner: test-owner.close
    control-owner.close

  if not failures.is-empty:
    print "uart2-bigdata-ec618: FAIL $failures"
    throw "UART2 big-data failed: $failures"
  print "uart2-bigdata-ec618: PASS TX=$TX-TOTAL RX=$RX-TOTAL sustained bytes at $BAUDS, no leak"
