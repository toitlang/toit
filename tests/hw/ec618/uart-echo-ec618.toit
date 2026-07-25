// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

import .framed-control show FramedChannel
import .wiring as wiring

/**
EC618 half of the exhaustive UART1/UART2 round-trip test.

UART1 initially carries the framed control protocol while UART2 is swept. The
  boards then handshake a control-lane switch to UART2 and sweep UART1. Each
  controller is tested in two modes: reopening at every baud, and changing the
  baud on one open port. The ESP32 acknowledges every port transition before
  test data is sent, so the test contains no timing sleeps.
*/

CONTROL-BAUD ::= 115200
CONTROL-TIMEOUT-MS ::= 10_000
ECHO-TIMEOUT-MS ::= 5_000
UART1-BAUDS ::= [115200, 460800, 921600]
UART2-BAUDS ::= [9600, 115200, 921600, 1500000, 2000000, 3000000, 4000000]

class OwnedPort:
  id/int
  tx/gpio.Pin
  rx/gpio.Pin
  port/uart.Port

  constructor .id baud/int:
    tx-pad := id == 1 ? wiring.EC618-UART1-TX-PAD : wiring.EC618-UART2-TX-PAD
    rx-pad := id == 1 ? wiring.EC618-UART1-RX-PAD : wiring.EC618-UART2-RX-PAD
    tx = gpio.Pin tx-pad
    rx = gpio.Pin rx-pad
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
    print "uart-echo-ec618: opened UART$id control"

  id -> int: return owned.id

  send message/string -> none:
    channel.send message

  expect expected/string -> none:
    channel.expect expected --timeout-ms=CONTROL-TIMEOUT-MS

  close -> none:
    owned.close

main:
  control := Control 1
  try:
    control.send "HELLO 1"
    control.expect "READY 1"

    test-uart control 2 UART2-BAUDS
    control = switch-control control 2
    test-uart control 1 UART1-BAUDS

    control.send "Q"
    control.expect "BYE"
  finally:
    control.close
  print "uart-echo-ec618: PASS UART1 and UART2 TX+RX in reopen and set-baud modes"

test-uart control/Control id/int bauds/List -> none:
  test/OwnedPort? := null
  try:
    run-sweep control id bauds "reopen": | baud/int |
      if test:
        test.close
        test = null
      test = OwnedPort id baud
      control.send "OPEN $id $baud"
      control.expect "READY $id $baud"
      FramedChannel test.port

    test.close
    test = null
    test = OwnedPort id bauds[0]
    control.send "OPEN $id $bauds[0]"
    control.expect "READY $id $bauds[0]"
    channel := FramedChannel test.port
    run-sweep control id bauds "set-baud": | baud/int |
      test.port.baud-rate = baud
      control.send "BAUD $id $baud"
      control.expect "READY $id $baud"
      channel

    test.close
    test = null
    control.send "CLOSE $id"
    control.expect "CLOSED $id"
  finally:
    if test: test.close

run-sweep control/Control id/int bauds/List mode/string [configure] -> none:
  print "uart-echo-ec618: UART$id mode=$mode, sweep $bauds"
  bauds.do: | baud/int |
    channel/FramedChannel := configure.call baud
    round-trip control channel id baud mode

round-trip control/Control test/FramedChannel id/int baud/int mode/string -> none:
  payload := "UART$id/$mode/$baud|" + ("0123456789ABCDEF" * 10)
  control.send "ECHO $id $baud $payload.byte-size"
  control.expect "READY-ECHO $id $baud"
  test.send payload
  echoed := test.receive --timeout-ms=ECHO-TIMEOUT-MS
  control.expect "ECHOED $id $baud"
  if echoed != payload:
    throw "UART$id $mode round-trip mismatch at $baud baud"
  print "uart-echo-ec618: UART$id baud=$baud [$mode] round-trip ok"

switch-control old/Control id/int -> Control:
  replacement := Control id
  old.send "SWITCH $id"
  old.expect "SWITCHING $id"
  replacement.expect "HELLO $id"
  replacement.send "READY $id"
  replacement.expect "ACTIVE $id"
  old.close
  print "uart-echo-ec618: control moved to UART$id"
  return replacement
