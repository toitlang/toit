// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import spi
import system
import uart

import .test
import .variants

RX1 ::= Variant.CURRENT.board-connection-pin1
TX1 ::= Variant.CURRENT.board-connection-pin2
RX2 ::= Variant.CURRENT.board-connection-pin2
TX2 ::= Variant.CURRENT.board-connection-pin1

CS ::= Variant.CURRENT.board-connection-pin3
SCLK ::= Variant.CURRENT.board-connection-pin4
MOSI ::= Variant.CURRENT.board-connection-pin5
MISO ::= Variant.CURRENT.board-connection-pin6

PREPARE ::= 0x31
SYNC ::= 0xa0
READY ::= 0xa1
DONE ::= 0xa2

FLAG-TRANSMIT-LSB-FIRST ::= 1 << 0
FLAG-RECEIVE-LSB-FIRST ::= 1 << 1
FLAG-USE-MOSI ::= 1 << 2
FLAG-USE-MISO ::= 1 << 3

class Case:
  name/string
  frequency/int
  mode/int
  transmit/ByteArray
  controller-data/ByteArray
  receive-size/int
  max-transfer-size/int
  fill-byte/int
  dma/bool
  transmit-lsb-first/bool
  receive-lsb-first/bool
  use-mosi/bool
  use-miso/bool

  constructor
      .name
      --.frequency
      --.mode=0
      --.transmit
      --.controller-data
      --.receive-size=controller-data.size
      --.max-transfer-size=(transmit.size > controller-data.size
          ? transmit.size
          : controller-data.size)
      --.fill-byte=0xff
      --.dma=true
      --.transmit-lsb-first=false
      --.receive-lsb-first=false
      --.use-mosi=true
      --.use-miso=true:

main-board1:
  run-test: test-board1

test-board1:
  port := uart.Port --rx=RX1 --tx=TX1 --baud-rate=115200
  expect-equals SYNC port.in.read-byte
  bus := spi.Bus --clock=SCLK --mosi=MOSI --miso=MISO
  is-classic-esp32 := system.architecture == system.ARCHITECTURE-ESP32

  cases := []
  4.repeat: | mode/int |
    [false, true].do: | dma/bool |
      suffix := dma ? "dma" : "no-dma"
      if not dma or (mode & 1) == 0:
        cases.add (Case "mode-$(mode)-receive-$suffix"
            --frequency=400_000
            --mode=mode
            --transmit=#[ ]
            --controller-data=(pattern 16 (0x10 + mode))
            --max-transfer-size=(dma ? 16 : 64)
            --dma=dma
            --use-miso=false)
      cases.add (Case "mode-$(mode)-transmit-$suffix"
          --frequency=400_000
          --mode=mode
          --transmit=(pattern 16 (0x40 + mode))
          --controller-data=(pattern 16 (0x10 + mode))
          --receive-size=0
          --max-transfer-size=(dma ? 16 : 64)
          --dma=dma
          --use-mosi=false)

  [50_000, 100_000, 400_000, 1_000_000, 2_000_000].do: | frequency/int |
    if is-classic-esp32:
      cases.add (Case "frequency-$(frequency)-receive"
          --frequency=frequency
          --transmit=#[ ]
          --controller-data=(pattern 32 0x15)
          --max-transfer-size=64
          --dma=false
          --use-miso=false)
      cases.add (Case "frequency-$(frequency)-transmit"
          --frequency=frequency
          --transmit=(pattern 32 0x51)
          --controller-data=(pattern 32 0x15)
          --receive-size=0
          --max-transfer-size=64
          --dma=false
          --use-mosi=false)
    else:
      cases.add (Case "frequency-$frequency"
          --frequency=frequency
          --transmit=(pattern 32 0x51)
          --controller-data=(pattern 32 0x15)
          --max-transfer-size=64
          --dma=false)

  cases.add (Case "transmit-lsb-first"
      --frequency=1_000_000
      --transmit=#[0x01, 0x96, 0xe3, 0x55]
      --controller-data=#[0x12, 0x34, 0x56, 0x78]
      --receive-size=0
      --max-transfer-size=64
      --dma=false
      --use-mosi=false
      --transmit-lsb-first)
  cases.add (Case "receive-lsb-first"
      --frequency=1_000_000
      --transmit=#[ ]
      --controller-data=#[0x12, 0x34, 0x56, 0x78]
      --max-transfer-size=64
      --dma=false
      --use-miso=false
      --receive-lsb-first)
  cases.add (Case "both-lsb-first"
      --frequency=1_000_000
      --transmit=#[0x01, 0x96, 0xe3, 0x55]
      --controller-data=#[0x12, 0x34, 0x56, 0x78]
      --max-transfer-size=64
      --dma=false
      --transmit-lsb-first
      --receive-lsb-first)

  [1, 3, 4, 17, 64].do: | size/int |
    cases.add (Case "non-dma-$size"
        --frequency=1_000_000
        --transmit=(pattern size 0x62)
        --controller-data=(pattern size 0x26)
        --max-transfer-size=64
        --dma=false)

  [1, 3, 4, 17, 257, 4_092].do: | size/int |
    frequency := size > 1_000 ? 5_000_000 : 1_000_000
    if is-classic-esp32:
      cases.add (Case "dma-receive-$size"
          --frequency=frequency
          --transmit=#[ ]
          --controller-data=(pattern size 0x37)
          --max-transfer-size=4_092
          --use-miso=false)
      cases.add (Case "dma-transmit-$size"
          --frequency=frequency
          --transmit=(pattern size 0x73)
          --controller-data=(pattern size 0x37)
          --receive-size=0
          --max-transfer-size=4_092
          --use-mosi=false)
    else:
      cases.add (Case "dma-$size"
          --frequency=frequency
          --transmit=(pattern size 0x73)
          --controller-data=(pattern size 0x37)
          --max-transfer-size=4_092)

  cases.add (Case "fill"
      --frequency=1_000_000
      --transmit=#[1, 2, 3]
      --controller-data=(pattern 12 0x48)
      --receive-size=12
      --max-transfer-size=64
      --dma=false
      --fill-byte=0xa5)

  cases.add (Case "controller-ends-early"
      --frequency=1_000_000
      --transmit=(pattern 32 0x84)
      --controller-data=(pattern 7 0x49)
      --receive-size=32
      --max-transfer-size=64
      --dma=false)

  cases.add (Case "target-transmit-only"
      --frequency=1_000_000
      --transmit=(pattern 19 0x95)
      --controller-data=(pattern 19 0x59)
      --receive-size=0
      --max-transfer-size=19
      --use-mosi=false)

  cases.add (Case "target-receive-only"
      --frequency=1_000_000
      --transmit=#[ ]
      --controller-data=(pattern 19 0x6a)
      --receive-size=19
      --max-transfer-size=19
      --use-miso=false)

  cases.do: | current/Case |
    print "SPI target: $(current.name)"
    device := bus.device
        --cs=CS
        --frequency=current.frequency
        --mode=current.mode
        --cs-setup-cycles=1
    // Keep CS at its inactive level before the target arms the peripheral.
    // A floating CS can otherwise look like an immediate zero-bit transfer.
    prepare-target port current

    controller-result := current.controller-data.copy
    device.transfer controller-result --read=true
    device.close

    target-result := read-target-result port
    expected-target := current.controller-data.copy
    if current.receive-lsb-first: reverse-bits-in-place expected-target
    expected-size := current.receive-size < expected-target.size
        ? current.receive-size
        : expected-target.size
    expected-target = expected-target.copy 0 expected-size
    expect-equals expected-target target-result

    if current.use-miso:
      expected-controller := ByteArray current.controller-data.size
      expected-controller.fill current.fill-byte
      copy-size := current.transmit.size < expected-controller.size
          ? current.transmit.size
          : expected-controller.size
      expected-controller.replace 0 (current.transmit.copy 0 copy-size)
      if current.transmit-lsb-first: reverse-bits-in-place expected-controller
      expect-equals expected-controller controller-result

  bus.close
  if is-classic-esp32:
    [1, 3].do: | mode/int |
      expect-throws "INVALID_ARGUMENT":
        spi.Target
            --mosi=MOSI
            --clock=SCLK
            --cs=CS
            --mode=mode
            --dma=true
    expect-throws "INVALID_ARGUMENT":
      spi.Target
          --mosi=MOSI
          --miso=MISO
          --clock=SCLK
          --cs=CS
          --mode=0
          --dma=true
  port.close

main-board2:
  run-test --background: test-board2

test-board2:
  port := uart.Port --rx=RX2 --tx=TX2 --baud-rate=115200
  port.out.write #[SYNC] --flush
  while true:
    command := port.in.read-byte
    if command != PREPARE: throw "Unknown command: $command"

    mode := port.in.read-byte
    flags := port.in.read-byte
    dma := port.in.read-byte != 0
    fill-byte := port.in.read-byte
    max-transfer-size := port.in.little-endian.read-uint32
    receive-size := port.in.little-endian.read-uint32
    transmit-size := port.in.little-endian.read-uint32
    transmit := port.in.read-bytes transmit-size

    target := spi.Target
        --mosi=((flags & FLAG-USE-MOSI) != 0 ? MOSI : null)
        --miso=((flags & FLAG-USE-MISO) != 0 ? MISO : null)
        --clock=SCLK
        --cs=CS
        --mode=mode
        --transmit-lsb-first=((flags & FLAG-TRANSMIT-LSB-FIRST) != 0)
        --receive-lsb-first=((flags & FLAG-RECEIVE-LSB-FIRST) != 0)
        --max-transfer-size=max-transfer-size
        --dma=dma

    pending := target.start-exchange transmit
        --receive-size=receive-size
        --fill-byte=fill-byte
    port.out.write #[READY] --flush

    result := pending.wait
    port.out.write #[DONE] --flush
    port.out.little-endian.write-uint32 result.size
    port.out.write result --flush
    target.close

prepare-target port/uart.Port current/Case:
  flags := 0
  if current.transmit-lsb-first: flags |= FLAG-TRANSMIT-LSB-FIRST
  if current.receive-lsb-first: flags |= FLAG-RECEIVE-LSB-FIRST
  if current.use-mosi: flags |= FLAG-USE-MOSI
  if current.use-miso: flags |= FLAG-USE-MISO

  port.out.write #[
    PREPARE,
    current.mode,
    flags,
    current.dma ? 1 : 0,
    current.fill-byte,
  ]
  port.out.little-endian.write-uint32 current.max-transfer-size
  port.out.little-endian.write-uint32 current.receive-size
  port.out.little-endian.write-uint32 current.transmit.size
  port.out.write current.transmit --flush
  expect-equals READY port.in.read-byte

read-target-result port/uart.Port -> ByteArray:
  expect-equals DONE port.in.read-byte
  size := port.in.little-endian.read-uint32
  return port.in.read-bytes size

pattern size/int seed/int -> ByteArray:
  result := ByteArray size
  size.repeat: | index/int |
    result[index] = (seed + index * 37) & 0xff
  return result

reverse-bits-in-place bytes/ByteArray -> none:
  bytes.size.repeat: | index/int |
    value := bytes[index]
    value = ((value & 0x55) << 1) | ((value >> 1) & 0x55)
    value = ((value & 0x33) << 2) | ((value >> 2) & 0x33)
    bytes[index] = ((value << 4) | (value >> 4)) & 0xff

expect-throws expected [code]:
  expect-equals expected (catch code)
