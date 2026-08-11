// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import gpio
import i2c
import rmt
import system
import uart

import .test
import .variants

UART-RX1 ::= Variant.CURRENT.board-connection-pin1
UART-TX1 ::= Variant.CURRENT.board-connection-pin2
UART-RX2 ::= Variant.CURRENT.board-connection-pin2
UART-TX2 ::= Variant.CURRENT.board-connection-pin1

I2C-SDA ::= Variant.CURRENT.board-connection-pin4
// Pin 5 is resistor-coupled to pin 6 on board 1. Pin 6 is deliberately left
// free so later timing tests can use it as a non-invasive SCL probe.
I2C-SCL ::= Variant.CURRENT.board-connection-pin5
I2C-SCL-PROBE ::= Variant.CURRENT.board-connection-pin6

ADDRESS ::= 0x42
TEN-BIT-ADDRESS ::= 0x2aa
FREQUENCY ::= 100_000

READY ::= 0xa5
OK ::= 0x5a

WRITE ::= 1
QUEUE-READ ::= 2
WRITE-READ ::= 3
CLOSE ::= 4
DYNAMIC-READ ::= 5
RECONFIGURE ::= 6
OVERFLOW ::= 7
TRANSACTION-OVERFLOW ::= 8

DEFAULT-CONFIG ::= 0
TEN-BIT-CONFIG ::= 1
SMALL-BUFFER-CONFIG ::= 2
BROADCAST-CONFIG ::= 3

main-board1:
  run-test: test-board1

test-board1:
  port := uart.Port --rx=UART-RX1 --tx=UART-TX1 --baud-rate=115_200
  expect-equals READY port.in.read-byte

  bus := i2c.Bus --sda=I2C-SDA --scl=I2C-SCL --frequency=FREQUENCY --pull-up
  expect (bus.test ADDRESS)
  device := bus.device ADDRESS

  [1, 2, 15, 31, 32, 63].do: | size/int |
    data := make-data size size
    send-command port WRITE [data]
    device.write data
    expect-equals OK port.in.read-byte

  [1, 2, 15, 31, 32, 63].do: | size/int |
    expected := make-data size (size + 0x40)
    send-command port QUEUE-READ [expected]
    expect-equals expected (device.read size)
    expect-equals OK port.in.read-byte

  if system.architecture != system.ARCHITECTURE-ESP32:
    expected := make-data 17 0x91
    send-command port DYNAMIC-READ [expected]
    // GPIO38 drives the S3 devkit's onboard RGB LED and needs a local pull-up
    // to be a reliable high-impedance probe through the 5K resistor.
    probe-pin := gpio.Pin I2C-SCL-PROBE --input --pull-up
    probe := rmt.In
        probe-pin  // @no-warn
        --resolution=1_000_000
        --memory-blocks=8
        --dma
    probe.start-reading --min-ns=1_000 --max-ns=20_000_000
    start := Time.monotonic-us
    expect-equals expected (device.read expected.size)
    elapsed := Time.monotonic-us - start
    expect elapsed >= 10_000
    expect elapsed < 100_000
    expect-equals OK port.in.read-byte
    scl-signals := probe.wait-for-data
    longest-low := 0
    scl-signals.size.repeat: | i/int |
      if (scl-signals.level i) == 0:
        longest-low = max longest-low (scl-signals.period i)
    print "I2C SCL probe: $(scl-signals.size) signals, longest low $(longest-low)us"
    // Ordinary 100kHz SCL low periods are about 5us. The target deliberately
    // waits 10ms after its request callback, which must be visible as one
    // continuous SCL-low stretch on the resistor-coupled probe pin.
    expect longest-low >= 9_000
    expect longest-low < 20_000
    probe.close
    probe-pin.close

  tx := make-data 19 0x71
  expected-rx := make-data 23 0x29
  send-command port WRITE-READ [tx, expected-rx]
  expect-equals expected-rx (device.write-read tx expected-rx.size)
  expect-equals OK port.in.read-byte

  device.close
  reconfigure port TEN-BIT-CONFIG
  device = bus.device TEN-BIT-ADDRESS --address-size=10
  ten-bit-write := make-data 29 0x37
  send-command port WRITE [ten-bit-write]
  device.write ten-bit-write
  expect-equals OK port.in.read-byte
  ten-bit-read := make-data 27 0xb2
  send-command port QUEUE-READ [ten-bit-read]
  expect-equals ten-bit-read (device.read ten-bit-read.size)
  expect-equals OK port.in.read-byte

  device.close
  reconfigure port SMALL-BUFFER-CONFIG
  device = bus.device ADDRESS
  small-buffer-write := make-data 31 0x84
  send-command port WRITE [small-buffer-write]
  device.write small-buffer-write
  expect-equals OK port.in.read-byte
  small-buffer-read := make-data 8 0x13
  send-command port QUEUE-READ [small-buffer-read]
  expect-equals small-buffer-read (device.read small-buffer-read.size)
  expect-equals OK port.in.read-byte

  first := make-data 31 0x51
  second := make-data 31 0xc1
  send-command port OVERFLOW [first]
  device.write first
  device.write second
  expect-equals OK port.in.read-byte

  // Distinguish a transaction larger than the driver's receive buffer from
  // an application that merely leaves too many complete transactions unread.
  reconfigure port SMALL-BUFFER-CONFIG
  oversized := make-data 63 0x6d
  send-command port TRANSACTION-OVERFLOW []
  device.write oversized
  expect-equals OK port.in.read-byte

  if system.architecture != system.ARCHITECTURE-ESP32:
    device.close
    reconfigure port BROADCAST-CONFIG
    device = bus.device ADDRESS
    general-call := bus.device 0
    broadcast-data := make-data 21 0xe3
    send-command port WRITE [broadcast-data]
    general-call.write broadcast-data
    expect-equals OK port.in.read-byte
    general-call.close

  port.out.write-byte CLOSE
  port.out.flush
  expect-equals OK port.in.read-byte

  device.close
  bus.close
  port.close

main-board2:
  run-test --background: test-board2

test-board2:
  target := make-target DEFAULT-CONFIG
  expect-null target.try-read
  expect-equals 0 target.dropped-receive-count

  port := uart.Port --rx=UART-RX2 --tx=UART-TX2 --baud-rate=115_200
  send-byte port READY

  while true:
    command := port.in.read-byte
    if command == CLOSE:
      target.close
      send-byte port OK
      port.close
      return

    parts := read-parts port
    if command == RECONFIGURE:
      target.close
      target = make-target parts[0][0]
      send-byte port READY
      send-byte port OK
    else if command == WRITE:
      send-byte port READY
      expect-equals parts[0] target.read
      send-byte port OK
    else if command == QUEUE-READ:
      target.write parts[0]
      send-byte port READY
      target.wait-for-read-request
      send-byte port OK
    else if command == DYNAMIC-READ:
      send-byte port READY
      target.wait-for-read-request
      sleep --ms=10
      target.write parts[0]
      send-byte port OK
    else if command == WRITE-READ:
      target.write parts[1]
      send-byte port READY
      expect-equals parts[0] target.read
      send-byte port OK
    else if command == OVERFLOW:
      send-byte port READY
      sleep --ms=30
      expect-throw "OVERFLOW": target.try-read
      expect-equals parts[0] target.read
      expect-null target.try-read
      expect target.dropped-receive-count >= 1
      send-byte port OK
    else if command == TRANSACTION-OVERFLOW:
      send-byte port READY
      sleep --ms=30
      expect-throw "OVERFLOW": target.try-read
      expect-null target.try-read
      expect-equals 1 target.dropped-receive-count
      send-byte port OK
    else:
      throw "Unknown command: $command"

make-target config/int -> i2c.Target:
  if config == DEFAULT-CONFIG:
    return i2c.Target
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --send-buffer-size=128
        --receive-buffer-size=256
        --pull-up
  if config == TEN-BIT-CONFIG:
    return i2c.Target
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=TEN-BIT-ADDRESS
        --address-size=10
        --send-buffer-size=64
        --receive-buffer-size=64
        --pull-up
  if config == SMALL-BUFFER-CONFIG:
    return i2c.Target
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --send-buffer-size=8
        --receive-buffer-size=32
        --no-pull-up
  if config == BROADCAST-CONFIG:
    return i2c.Target
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --send-buffer-size=32
        --receive-buffer-size=32
        --pull-up
        --broadcast
  unreachable

reconfigure port/uart.Port config/int -> none:
  send-command port RECONFIGURE [#[config]]
  expect-equals OK port.in.read-byte

send-command port/uart.Port command/int parts/List -> none:
  port.out.write-byte command
  port.out.write-byte parts.size
  parts.do: | part/ByteArray |
    port.out.little-endian.write-uint16 part.size
    port.out.write part
  port.out.flush
  expect-equals READY port.in.read-byte

read-parts port/uart.Port -> List:
  count := port.in.read-byte
  return List count: | _ |
    size := port.in.little-endian.read-uint16
    port.in.read-bytes size

send-byte port/uart.Port value/int -> none:
  port.out.write-byte value
  port.out.flush

make-data size/int seed/int -> ByteArray:
  return ByteArray size: (seed + 17 * it) & 0xff
