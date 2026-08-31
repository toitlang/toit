// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor

import .framed-control show FramedChannel
import .uart-rig as rig
import .uart-stream as stream

/**
ESP32 command server for UART2 sustained, ring, and duplex tests.

The bidirectional UART1 control lane is length-delimited and CRC-protected.
  Raw UART2 data only starts after both peers acknowledge the phase.
*/

CONTROL-BAUD ::= 115200
CONTROL-TIMEOUT-MS ::= 35_000

main:
  control-owner := rig.esp32-uart 1 CONTROL-BAUD
  control := FramedChannel control-owner.port
  test-owner/rig.OwnedPort? := null

  try:
    while true:
      message := control.receive --timeout-ms=120_000
      parts := message.split " "
      command := parts[0]

      if command == "HELLO" and parts.size == 1:
        control.send "READY"
        print "uart2-bigdata-esp32: control ready"
      else if command == "BAUD" and parts.size == 2:
        baud := int.parse parts[1]
        if test-owner: test-owner.close
        test-owner = rig.esp32-uart 2 baud
        control.send "READY $baud"
        print "uart2-bigdata-esp32: UART2 ready at $baud"
      else if command == "RECEIVE" and parts.size == 2:
        n := int.parse parts[1]
        if not test-owner: throw "test UART is not open"
        control.send "READY-RECEIVE $n"
        print "uart2-bigdata-esp32: receiving $n"
        result := stream.recv-stream test-owner.port n
        control.send "RECEIVED $result[0] $result[1]"
        print "uart2-bigdata-esp32: received $result[1]/$n"
      else if command == "SEND" and parts.size == 2:
        n := int.parse parts[1]
        if not test-owner: throw "test UART is not open"
        control.send "READY-SEND $n"
        control.expect "GO-SEND $n" --timeout-ms=CONTROL-TIMEOUT-MS
        print "uart2-bigdata-esp32: sending $n"
        stream.send-stream test-owner.port n
        control.send "SENT $n"
      else if command == "DUPLEX" and parts.size == 2:
        n := int.parse parts[1]
        if not test-owner: throw "test UART is not open"
        control.send "READY-DUPLEX $n"
        control.expect "GO-DUPLEX $n" --timeout-ms=CONTROL-TIMEOUT-MS
        received := monitor.Latch
        task:: received.set (stream.recv-stream test-owner.port n)
        stream.send-stream test-owner.port n
        result := received.get
        control.send "DUPLEXED $result[0] $result[1]"
      else if command == "Q":
        control.send "BYE"
        return
      else:
        throw "invalid control message '$message'"
  finally:
    if test-owner: test-owner.close
    control-owner.close
    print "uart2-bigdata-esp32: done"
