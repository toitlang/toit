// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor
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

CREATE ::= 0x41
WRITE ::= 0x42
SET ::= 0x43
READ ::= 0x44
RECEIVE ::= 0x45
DROPPED ::= 0x46
CLOSE ::= 0x47
RECEIVE-TIMEOUT ::= 0x48
READY ::= 0xb1
DONE ::= 0xb2
SYNC ::= 0xb3

FLAG-USE-MOSI ::= 1 << 0
FLAG-USE-MISO ::= 1 << 1
FLAG-DMA ::= 1 << 2
FLAG-TRANSMIT-LSB-FIRST ::= 1 << 3
FLAG-RECEIVE-LSB-FIRST ::= 1 << 4

main-board1:
  run-test: test-board1

test-board1:
  port := uart.Port --rx=RX1 --tx=TX1 --baud-rate=115200
  expect-equals SYNC port.in.read-byte
  bus := spi.Bus --clock=SCLK --mosi=MOSI --miso=MISO
  is-classic := system.architecture == system.ARCHITECTURE-ESP32

  print "SPI buffer target: response and early termination"
  initial := #[1, 2, 3, 4, 5]
  create-target port
      --mode=0
      --buffer-size=64
      --queue-depth=4
      --fill-byte=0xa5
      --initial=initial
      --use-mosi
      --use-miso
      --dma=false
  device := create-device bus --mode=0 --frequency=1_000_000
  port.out.write #[RECEIVE-TIMEOUT] --flush
  expect-equals DONE port.in.read-byte
  sent := pattern 17 0x20
  received := transfer device sent
  expected := ByteArray sent.size
  expected.fill 0xa5
  expected.replace 0 initial
  expect-equals expected received
  expect-equals sent (take-received port)

  print "SPI buffer target: native response access"
  write-response port 3 #[0x91, 0x92, 0x93, 0x94]
  set-response port 1 0x81
  expect-equals #[0x81, 3, 0x91, 0x92, 0x93] (read-response port 1 5)
  // A non-DMA target can have already copied its response to the peripheral's
  // registers. Complete one transaction so the re-arm observes the update.
  priming := pattern 7 0x2a
  expect-equals #[1, 2, 3, 4, 5, 0xa5, 0xa5] (transfer device priming)
  expect-equals priming (take-received port)
  sent = pattern 9 0x30
  received = transfer device sent
  expect-equals #[1, 0x81, 3, 0x91, 0x92, 0x93, 0x94, 0xa5, 0xa5] received
  expect-equals sent (take-received port)

  print "SPI buffer target: modes and bit order"
  close-target port
  device.close
  [
    [0, false, false],
    [1, false, false],
    [2, false, false],
    [3, false, false],
    [0, true, false],
    [0, false, true],
    [0, true, true],
  ].do: | current/List |
    mode/int := current[0]
    transmit-lsb-first/bool := current[1]
    receive-lsb-first/bool := current[2]
    print "SPI buffer target: mode=$mode tx-lsb=$transmit-lsb-first rx-lsb=$receive-lsb-first"
    response := pattern 16 (0x15 + mode)
    sent = pattern 16 (0x91 + mode)
    create-target port
        --mode=mode
        --buffer-size=16
        --queue-depth=2
        --fill-byte=0xff
        --initial=response
        --use-mosi
        --use-miso
        --dma=false
        --transmit-lsb-first=transmit-lsb-first
        --receive-lsb-first=receive-lsb-first
    device = create-device bus --mode=mode --frequency=1_000_000
    expected-response := response.copy
    if transmit-lsb-first: reverse-bits-in-place expected-response
    expect-equals expected-response (transfer device sent)
    expected-receive := sent.copy
    if receive-lsb-first: reverse-bits-in-place expected-receive
    expect-equals expected-receive (take-received port)
    close-target port
    device.close

  print "SPI buffer target: receive queue overflow"
  create-target port
      --mode=0
      --buffer-size=16
      --queue-depth=3
      --fill-byte=0x5a
      --initial=#[ ]
      --use-mosi
      --use-miso
      --dma=false
  device = create-device bus --mode=0 --frequency=2_000_000
  3.repeat: | round/int |
    5.repeat: | index/int |
      data := pattern 16 (0x40 + round * 8 + index)
      expect-equals (filled 16 0x5a) (transfer device data)
    expect-equals (round + 1) * 2 (dropped port)
    3.repeat: | index/int |
      expect-equals
          (pattern 16 (0x40 + round * 8 + index))
          (take-received port)

  print "SPI buffer target: receive wait and repeated re-arm"
  port.out.write #[RECEIVE] --flush
  awaited := pattern 11 0x61
  expect-equals (filled 11 0x5a) (transfer device awaited)
  expect-equals awaited (read-received-result port)

  close-target port
  device.close
  create-target port
      --mode=0
      --buffer-size=16
      --queue-depth=16
      --fill-byte=0x3c
      --initial=#[ ]
      --use-mosi
      --use-miso
      --dma=false
  device = create-device bus --mode=0 --frequency=2_000_000
  16.repeat: | index/int |
    data := pattern 16 (0x70 + index)
    expect-equals (filled 16 0x3c) (transfer device data)
  expect-equals 0 (dropped port)
  16.repeat: | index/int |
    expect-equals (pattern 16 (0x70 + index)) (take-received port)

  print "SPI controller: asynchronous transfer and bus acquisition"
  close-target port
  device.close
  create-target port
      --mode=0
      --buffer-size=64
      --queue-depth=2
      --fill-byte=0x6d
      --initial=#[ ]
      --use-mosi
      --use-miso=false
      --dma=false
  device = create-device bus --mode=0 --frequency=50_000
  large-write := pattern 64 0x37
  ran-while-waiting := monitor.Latch
  task::
    sleep --ms=2
    ran-while-waiting.set true
  device.write large-write
  // At 50kHz this transaction takes over 10ms. The other Toit task can only
  // run before completion if the native transfer primitive returns immediately.
  expect ran-while-waiting.has-value
  expect-equals large-write (take-received port)

  // Try-acquire must not leave a pending bus-lock request when a background
  // transfer owns the peripheral. Repeated contention also checks that every
  // failed attempt is rolled back before the next one.
  3.repeat:
    transfer-started := monitor.Latch
    transfer-done := monitor.Latch
    task::
      transfer-started.set true
      device.write large-write
      transfer-done.set true
    transfer-started.get
    sleep --ms=2
    device.with-reserved-bus:
      null
    transfer-done.get
    expect-equals large-write (take-received port)

  print "SPI buffer target: DMA directions and maximum size"
  close-target port
  device.close
  if is-classic:
    create-target port
        --mode=0
        --buffer-size=4_092
        --queue-depth=2
        --fill-byte=0xff
        --initial=#[ ]
        --use-mosi
        --use-miso=false
        --dma=true
    device = create-device bus --mode=0 --frequency=5_000_000
    // Classic ESP32 target DMA only commits complete four-byte receive words.
    // An external controller can still release CS on any byte boundary, so
    // verify that the API omits the discarded trailing byte.
    partial-rx := pattern 17 0x17
    transfer device partial-rx
    expect-equals (partial-rx.copy 0 16) (take-received port)
    large-rx := pattern 4_092 0x19
    transfer device large-rx
    expect-equals large-rx (take-received port)

    close-target port
    device.close
    large-tx := pattern 4_092 0x91
    create-target port
        --mode=0
        --buffer-size=4_092
        --queue-depth=2
        --fill-byte=0xff
        --initial=large-tx
        --use-mosi=false
        --use-miso
        --dma=true
    device = create-device bus --mode=0 --frequency=5_000_000
    expect-equals large-tx (transfer device (ByteArray 4_092))
  else:
    large-tx := pattern 4_092 0x91
    create-target port
        --mode=2
        --buffer-size=4_092
        --queue-depth=2
        --fill-byte=0xff
        --initial=large-tx
        --use-mosi
        --use-miso
        --dma=true
    device = create-device bus --mode=2 --frequency=5_000_000
    large-rx := pattern 4_092 0x19
    expect-equals large-tx (transfer device large-rx)
    expect-equals large-rx (take-received port)

  close-target port
  device.close

  3.repeat:
    [false, true].do: | dma/bool |
      suffix := dma ? "dma" : "no-dma"
      print "SPI buffer target: active close-$suffix"
      create-target port
          --mode=0
          --buffer-size=64
          --queue-depth=2
          --fill-byte=0xff
          --initial=#[ ]
          --use-mosi
          --use-miso=false
          --dma=dma
      device = create-device bus
          --mode=0
          --frequency=(dma ? 400_000 : 100_000)
      device.with-reserved-bus:
        device.transfer #[0x5a] --keep-cs-active
        // Closing must not wait for CS to be released by the controller.
        close-target port
        // The target has disconnected its CS input, so this only terminates the
        // controller-side reservation.
        device.transfer #[0]
      device.close

      // Closing must also release the peripheral and pins for a new target.
      create-target port
          --mode=0
          --buffer-size=8
          --queue-depth=2
          --fill-byte=0xff
          --initial=#[ ]
          --use-mosi
          --use-miso=false
          --dma=dma
      device = create-device bus
          --mode=0
          --frequency=(dma ? 400_000 : 100_000)
      recovery := pattern 8 (dma ? 0xd1 : 0x1d)
      transfer device recovery
      expect-equals recovery (take-received port)
      close-target port
      device.close

  bus.close
  port.close

main-board2:
  run-test --background: test-board2

test-board2:
  expect-throw "INVALID_ARGUMENT":
    spi.BufferTarget
        --mosi=MOSI
        --clock=SCLK
        --cs=CS
        --buffer-size=4_093

  port := uart.Port --rx=RX2 --tx=TX2 --baud-rate=115200
  target/spi.BufferTarget? := null
  port.out.write #[SYNC] --flush

  while true:
    command := port.in.read-byte
    if command == CREATE:
      if target: target.close
      mode := port.in.read-byte
      flags := port.in.read-byte
      fill-byte := port.in.read-byte
      buffer-size := port.in.little-endian.read-uint32
      queue-depth := port.in.little-endian.read-uint32
      initial-size := port.in.little-endian.read-uint32
      initial := port.in.read-bytes initial-size
      target = spi.BufferTarget initial
          --mosi=((flags & FLAG-USE-MOSI) != 0 ? MOSI : null)
          --miso=((flags & FLAG-USE-MISO) != 0 ? MISO : null)
          --clock=SCLK
          --cs=CS
          --mode=mode
          --buffer-size=buffer-size
          --receive-queue-depth=queue-depth
          --fill-byte=fill-byte
          --transmit-lsb-first=((flags & FLAG-TRANSMIT-LSB-FIRST) != 0)
          --receive-lsb-first=((flags & FLAG-RECEIVE-LSB-FIRST) != 0)
          --dma=(flags & FLAG-DMA) != 0
      port.out.write #[READY] --flush
    else if command == WRITE:
      offset := port.in.little-endian.read-uint32
      size := port.in.little-endian.read-uint32
      target.write offset (port.in.read-bytes size)
      port.out.write #[DONE] --flush
    else if command == SET:
      index := port.in.little-endian.read-uint32
      value := port.in.read-byte
      target[index] = value
      expect-equals value target[index]
      port.out.write #[DONE] --flush
    else if command == READ:
      index := port.in.little-endian.read-uint32
      size := port.in.little-endian.read-uint32
      data := target.read index size
      port.out.little-endian.write-uint32 data.size
      port.out.write data --flush
    else if command == RECEIVE:
      data := target.receive
      port.out.write #[DONE] --flush
      port.out.little-endian.write-uint32 data.size
      port.out.write data --flush
    else if command == RECEIVE-TIMEOUT:
      expect-throw DEADLINE-EXCEEDED-ERROR:
        with-timeout --ms=5: target.receive
      port.out.write #[DONE] --flush
    else if command == DROPPED:
      port.out.little-endian.write-uint32 target.dropped-receive-count
      port.out.flush
    else if command == CLOSE:
      if target: target.close
      target = null
      port.out.write #[DONE] --flush
    else:
      throw "Unknown command: $command"

create-target port/uart.Port
    --mode/int
    --buffer-size/int
    --queue-depth/int
    --fill-byte/int
    --initial/ByteArray
    --use-mosi/bool
    --use-miso/bool
    --dma/bool
    --transmit-lsb-first/bool=false
    --receive-lsb-first/bool=false:
  flags := 0
  if use-mosi: flags |= FLAG-USE-MOSI
  if use-miso: flags |= FLAG-USE-MISO
  if dma: flags |= FLAG-DMA
  if transmit-lsb-first: flags |= FLAG-TRANSMIT-LSB-FIRST
  if receive-lsb-first: flags |= FLAG-RECEIVE-LSB-FIRST
  port.out.write #[CREATE, mode, flags, fill-byte]
  port.out.little-endian.write-uint32 buffer-size
  port.out.little-endian.write-uint32 queue-depth
  port.out.little-endian.write-uint32 initial.size
  port.out.write initial --flush
  expect-equals READY port.in.read-byte

close-target port/uart.Port:
  port.out.write #[CLOSE] --flush
  expect-equals DONE port.in.read-byte

write-response port/uart.Port offset/int bytes/ByteArray:
  port.out.write #[WRITE]
  port.out.little-endian.write-uint32 offset
  port.out.little-endian.write-uint32 bytes.size
  port.out.write bytes --flush
  expect-equals DONE port.in.read-byte

set-response port/uart.Port index/int value/int:
  port.out.write #[SET]
  port.out.little-endian.write-uint32 index
  port.out.write #[value] --flush
  expect-equals DONE port.in.read-byte

read-response port/uart.Port index/int size/int -> ByteArray:
  port.out.write #[READ]
  port.out.little-endian.write-uint32 index
  port.out.little-endian.write-uint32 size
  port.out.flush
  result-size := port.in.little-endian.read-uint32
  return port.in.read-bytes result-size

take-received port/uart.Port -> ByteArray:
  port.out.write #[RECEIVE] --flush
  return read-received-result port

read-received-result port/uart.Port -> ByteArray:
  expect-equals DONE port.in.read-byte
  size := port.in.little-endian.read-uint32
  return port.in.read-bytes size

dropped port/uart.Port -> int:
  port.out.write #[DROPPED] --flush
  return port.in.little-endian.read-uint32

create-device bus/spi.Bus --mode/int --frequency/int -> spi.Device:
  return bus.device
      --cs=CS
      --mode=mode
      --frequency=frequency
      --cs-setup-cycles=1

transfer device/spi.Device data/ByteArray -> ByteArray:
  result := data.copy
  device.transfer result --read=true
  return result

filled size/int value/int -> ByteArray:
  result := ByteArray size
  result.fill value
  return result

pattern size/int seed/int -> ByteArray:
  result := ByteArray size
  size.repeat: | index/int |
    result[index] = (seed + index * 37) & 0xff
  return result

reverse-bits-in-place bytes/ByteArray -> none:
  bytes.size.repeat: | index/int |
    value := bytes[index]
    reversed := 0
    8.repeat:
      reversed = (reversed << 1) | (value & 1)
      value >>= 1
    bytes[index] = reversed
