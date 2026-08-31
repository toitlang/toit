// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

import .framed-control show FramedChannel
import .wiring as wiring

/**
ESP32 half of the exhaustive UART1/UART2 round-trip test.

Commands arrive through a length-delimited, CRC-protected channel. The helper
  acknowledges each open or baud transition before receiving one framed test
  payload and echoing it. It switches the control lane from UART1 to UART2
  before UART1 becomes the test controller.
*/

CONTROL-BAUD ::= 115200
CONTROL-TIMEOUT-MS ::= 15_000
STARTUP-TIMEOUT-MS ::= 120_000
ECHO-TIMEOUT-MS ::= 5_000

class OwnedPort:
  id/int
  tx/gpio.Pin
  rx/gpio.Pin
  port/uart.Port

  constructor .id baud/int:
    tx-num := id == 1 ? wiring.ESP32-UART1-TX-PIN : wiring.ESP32-UART2-TX-PIN
    rx-num := id == 1 ? wiring.ESP32-UART1-RX-PIN : wiring.ESP32-UART2-RX-PIN
    tx = gpio.Pin tx-num
    rx = gpio.Pin rx-num
    port = uart.Port --tx=tx --rx=rx --baud-rate=baud

  close -> none:
    port.close
    rx.close
    tx.close

class Control:
  owned/OwnedPort
  channel/FramedChannel

  constructor id/int:
    owned = OwnedPort id CONTROL-BAUD
    channel = FramedChannel owned.port

  id -> int: return owned.id

  send message/string -> none:
    channel.send message

  receive --timeout-ms/int=CONTROL-TIMEOUT-MS -> string:
    return channel.receive --timeout-ms=timeout-ms

  expect expected/string -> none:
    channel.expect expected --timeout-ms=CONTROL-TIMEOUT-MS

  close -> none:
    owned.close

main:
  control := Control 1
  test/OwnedPort? := null
  test-channel/FramedChannel? := null
  connected := false
  try:
    while true:
      message := control.receive
          --timeout-ms=(connected ? CONTROL-TIMEOUT-MS : STARTUP-TIMEOUT-MS)
      parts := message.split " "
      command := parts[0]

      if command == "HELLO" and parts.size == 2:
        control.send "READY $parts[1]"
        connected = true
      else if command == "OPEN" and parts.size == 3:
        id := int.parse parts[1]
        baud := int.parse parts[2]
        if id == control.id: throw "cannot use UART$id as control and test"
        if test: test.close
        test = OwnedPort id baud
        test-channel = FramedChannel test.port
        control.send "READY $id $baud"
      else if command == "BAUD" and parts.size == 3:
        id := int.parse parts[1]
        baud := int.parse parts[2]
        if not test or test.id != id: throw "UART$id test port is not open"
        test.port.baud-rate = baud
        control.send "READY $id $baud"
      else if command == "ECHO" and parts.size == 4:
        id := int.parse parts[1]
        baud := int.parse parts[2]
        size := int.parse parts[3]
        if not test or test.id != id: throw "UART$id test port is not open"
        control.send "READY-ECHO $id $baud"
        payload := test-channel.receive --timeout-ms=ECHO-TIMEOUT-MS
        if payload.byte-size != size:
          throw "UART$id received $payload.byte-size bytes, expected $size"
        test-channel.send payload
        control.send "ECHOED $id $baud"
      else if command == "CLOSE" and parts.size == 2:
        id := int.parse parts[1]
        if not test or test.id != id: throw "UART$id test port is not open"
        test.close
        test = null
        test-channel = null
        control.send "CLOSED $id"
      else if command == "SWITCH" and parts.size == 2:
        id := int.parse parts[1]
        if test: throw "test port still open during control switch"
        replacement := Control id
        control.send "SWITCHING $id"
        replacement.send "HELLO $id"
        replacement.expect "READY $id"
        control.close
        control = replacement
        control.send "ACTIVE $id"
        print "uart-echo-esp32: control moved to UART$id"
      else if command == "Q":
        if test: throw "test port still open at shutdown"
        control.send "BYE"
        return
      else:
        throw "invalid control message '$message'"
  finally:
    if test: test.close
    control.close
    print "uart-echo-esp32: done"
