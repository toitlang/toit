// Copyright (C) 2025 Toit contributors
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import spi
import system
import uart

import ..shared.spi as shared
import .test
import .variants

FREQUENCY ::= 500

RX1 ::= Variant.CURRENT.board-connection-pin1
TX1 ::= Variant.CURRENT.board-connection-pin2
RX2 ::= Variant.CURRENT.board-connection-pin2
TX2 ::= Variant.CURRENT.board-connection-pin1

MASTER-CS ::= Variant.CURRENT.board-connection-pin3
MASTER-SCLK ::= Variant.CURRENT.board-connection-pin4
// Pin5 and 6 are connected with a 5K resistor.
MASTER-MOSI ::= Variant.CURRENT.board-connection-pin5
MASTER-MISO ::= Variant.CURRENT.board-connection-pin6

SLAVE-CS ::= Variant.CURRENT.board-connection-pin3
SLAVE-SCLK ::= Variant.CURRENT.board-connection-pin4
SLAVE-MOSI ::= Variant.CURRENT.board-connection-pin5
SLAVE-MISO ::= Variant.CURRENT.board-connection-pin6

main-board1:
  run-test: test-board1

test-board1:
  master-cs := gpio.Pin MASTER-CS
  master-sclk := gpio.Pin MASTER-SCLK
  master-mosi := gpio.Pin MASTER-MOSI
  master-miso := gpio.Pin MASTER-MISO

  rx := gpio.Pin RX1
  tx := gpio.Pin TX1
  port := uart.Port --rx=rx --tx=tx --baud-rate=115200

  slave := SlaveRemote port
  slave.sync

  bus := spi.Bus
      --clock=master-sclk
      --mosi=master-mosi
      --miso=master-miso

  // The minimum SPI frequency on the S3 is 100kHz. We can't bit-bang that.
  run-slave-receive := (system.architecture != system.ARCHITECTURE-ESP32S3)
  shared.test-spi
      --create-device=: | mode/int |
          bus.device
              --cs=master-cs
              --frequency=FREQUENCY
              --mode=mode
      --slave=slave
      --run-slave-receive=run-slave-receive

  master-cs.close
  master-sclk.close
  master-mosi.close
  master-miso.close

main-board2:
  run-test --background: test-board2

test-board2:
  slave-cs := gpio.Pin SLAVE-CS
  slave-sclk := gpio.Pin SLAVE-SCLK
  slave-mosi := gpio.Pin SLAVE-MOSI
  slave-miso := gpio.Pin SLAVE-MISO

  slave := shared.SlaveBitBang
      --cs=slave-cs
      --sclk=slave-sclk
      --mosi=slave-mosi
      --miso=slave-miso

  rx := gpio.Pin RX2
  tx := gpio.Pin TX2
  port := uart.Port --rx=rx --tx=tx --baud-rate=115200

  in := port.in
  out := port.out
  ok := : out.write #[SlaveRemote.OK] --flush
  // One 'ok' for the sync.
  ok.call
  while true:
    command := in.read-byte
    if command == SlaveRemote.RESET:
      slave.reset
      ok.call
    else if command == SlaveRemote.RECEIVE:
      bit-count := in.read-byte
      cpol := in.read-byte
      cpha := in.read-byte
      slave.prepare-receive bit-count --cpol=cpol --cpha=cpha
      ok.call
      e := catch:
        out.little-endian.write-uint32 slave.receive
      // Simply don't respond. This should lead to a timeout on the other side.
      if e: "Error while receiving: $e"
    else if command == SlaveRemote.SET_MISO:
      value/int? := in.read-byte
      if value == -1: value = null
      slave.set-miso value
      ok.call
    else:
      throw "Unknown command: $command"

class SlaveRemote implements shared.Slave:
  static OK ::= 0xAA
  static RESET ::= 0x01
  static SET_MISO ::= 0x02
  static RECEIVE ::= 0x03
  static BAD := 0xFF

  port_/uart.Port

  constructor .port_:

  reset -> none:
    send_ #[RESET]

  prepare-receive bit-count/int --cpol/int --cpha/int -> none:
    send_ #[RECEIVE, bit-count, cpol, cpha]

  receive -> int:
    return port_.in.little-endian.read-uint32

  set-miso value/int? -> none:
    if value == null: value = -1
    send_ #[SET_MISO, value]

  sync -> none:
    wait-for-ok_

  send_ data/ByteArray -> none:
    port_.out.write data --flush
    wait-for-ok_

  wait-for-ok_ -> none:
    ok := port_.in.read-byte
    expect-equals OK ok
