// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
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

I2C-SDA ::= Variant.CURRENT.board-connection-pin3
I2C-SCL ::= Variant.CURRENT.board-connection-pin5
I2C-SCL-PROBE ::= Variant.CURRENT.board-connection-pin6

ADDRESS ::= 0x42
TEN-BIT-ADDRESS ::= 0x2aa
FREQUENCY ::= 100_000

READY ::= 0xa5
OK ::= 0x5a
FINISH ::= 0x69

SET ::= 1
EXPECT-AFTER ::= 2
RECONFIGURE ::= 3
EXPECT-DROPPED-AFTER ::= 4
CLOSE ::= 5

DEFAULT-CONFIG ::= 0
WIDE-CONFIG ::= 1
SMALL-CONFIG ::= 2
BROADCAST-CONFIG ::= 3

main-board1:
  run-test: test-board1

test-board1:
  port := uart.Port --rx=UART-RX1 --tx=UART-TX1 --baud-rate=115_200
  expect-equals READY port.in.read-byte

  if system.architecture == system.ARCHITECTURE-ESP32:
    port.out.write-byte CLOSE
    port.out.flush
    expect-equals OK port.in.read-byte
    port.close
    return

  bus := i2c.Bus --sda=I2C-SDA --scl=I2C-SCL --frequency=FREQUENCY --pull-up
  device := bus.device ADDRESS
  registers := device.registers

  expect-throw "OUT_OF_RANGE": registers.read-bytes -1 1
  expect-throw "OUT_OF_RANGE": registers.read-bytes 256 1
  expect-throw "OUT_OF_RANGE": registers.write-bytes -1 #[]
  expect-throw "OUT_OF_RANGE": registers.write-bytes 256 #[]

  initial := make-data 256 0x31
  set-registers port 0 initial
  expect-equals initial (registers.read-bytes 0 initial.size)

  // Exercise the ISR refill path well beyond the 32-byte hardware FIFO.
  expect-equals (wrapped initial 17 100) (registers.read-bytes 17 100)

  // A read without a preceding pointer write continues after the number of
  // bytes actually clocked, not after the number prefetched into the FIFO.
  device.write #[30]
  expect-equals (wrapped initial 30 3) (device.read 3)
  expect-equals (wrapped initial 33 2) (device.read 2)

  // Controller reads and writes wrap at the end of the native register bank.
  device.write #[250]
  expect-equals (wrapped initial 250 20) (device.read 20)
  controller-write := make-data 12 0xc4
  initial = wrapped-write initial 250 controller-write
  expect-after port 0 initial:
    registers.write-bytes 250 controller-write

  // A data-bearing write leaves the current address immediately after the
  // written bytes, just like an address-only write selects its address.
  after-write := (250 + controller-write.size) % initial.size
  expect-equals (wrapped initial after-write 3) (device.read 3)
  expect-equals (wrapped initial (after-write + 3) 2) (device.read 2)

  // A Toit-side update is visible to the next transaction without any task
  // having to run at address match.
  live := make-data 19 0x91
  set-registers port 73 live
  initial = wrapped-write initial 73 live
  expect-equals live (registers.read-bytes 73 live.size)

  if system.architecture != system.ARCHITECTURE-ESP32:
    // The resistor-coupled neighboring pin probes SCL without loading it.
    // Unlike the dynamic Target test, the register target must not contain a
    // millisecond-scale stretch while a Toit task prepares its response.
    probe := rmt.In
        I2C-SCL-PROBE
        --resolution=1_000_000
        --memory-blocks=8
        --pull-up
        --dma
    probe.start-reading --min-ns=1_000 --max-ns=20_000_000
    expect-equals (wrapped initial 11 100) (registers.read-bytes 11 100)
    scl-signals := probe.wait-for-data
    longest-low := 0
    scl-signals.size.repeat: | i/int |
      if (scl-signals.level i) == 0:
        longest-low = max longest-low (scl-signals.period i)
    print "Register I2C SCL probe: $(scl-signals.size) signals, longest low $(longest-low)us"
    expect longest-low < 100
    probe.close

  device.close
  reconfigure port WIDE-CONFIG
  device = bus.device TEN-BIT-ADDRESS --address-size=10
  registers = device.registers --byte-size=2
  wide := make-data 512 0x57
  set-registers port 0 wide
  expect-equals (wrapped wide 0x01f3 37) (registers.read-bytes 0x01f3 37)
  wide-write := make-data 23 0xa8
  expect-after port 0x0107 wide-write:
    registers.write-bytes 0x0107 wide-write

  device.close
  reconfigure port SMALL-CONFIG
  device = bus.device ADDRESS
  registers = device.registers
  small := make-data 32 0x19
  set-registers port 0 small
  oversized := make-data 31 0xee
  expect-dropped-after port 0 small:
    // The pointer byte plus data cannot fit in the 16-byte receive buffer.
    registers.write-bytes 0 oversized

  if system.architecture != system.ARCHITECTURE-ESP32:
    device.close
    reconfigure port BROADCAST-CONFIG
    device = bus.device ADDRESS
    general-call := bus.device 0
    broadcast-value := #[0x7d]
    expect-after port 9 broadcast-value:
      general-call.write #[9, broadcast-value[0]]
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
  test-validation
  if system.architecture == system.ARCHITECTURE-ESP32:
    expect-throw "UNSUPPORTED": make-target DEFAULT-CONFIG
    port := uart.Port --rx=UART-RX2 --tx=UART-TX2 --baud-rate=115_200
    send-byte port READY
    expect-equals CLOSE port.in.read-byte
    send-byte port OK
    port.close
    return

  target := make-target DEFAULT-CONFIG
  test-local-api target
  port := uart.Port --rx=UART-RX2 --tx=UART-TX2 --baud-rate=115_200
  send-byte port READY

  while true:
    command := port.in.read-byte
    if command == CLOSE:
      target.close
      expect-throw "CLOSED": target[0]
      send-byte port OK
      port.close
      return

    parts := read-parts port
    if command == RECONFIGURE:
      target.close
      target = make-target parts[0][0]
      send-byte port READY
      send-byte port OK
      continue

    start := decode-index parts[0]
    if command == SET:
      target.write start parts[1]
      expect-equals parts[1] (target.read start parts[1].size)
      send-byte port READY
      send-byte port OK
    else if command == EXPECT-AFTER:
      send-byte port READY
      expect-equals FINISH port.in.read-byte
      expect-equals parts[1] (target.read start parts[1].size)
      send-byte port OK
    else if command == EXPECT-DROPPED-AFTER:
      send-byte port READY
      expect-equals FINISH port.in.read-byte
      expect-equals parts[1] (target.read start parts[1].size)
      expect-equals 1 target.dropped-write-count
      send-byte port OK
    else:
      throw "Unknown command: $command"

test-local-api target/i2c.RegisterTarget:
  expect-equals 0 target[0]
  target[0] = 0xa5
  expect-equals 0xa5 target[0]
  target[0] = 0
  expect-equals #[] (target.read target.size 0)
  target.write target.size #[]
  expect-throw "OUT_OF_BOUNDS": target[target.size]
  expect-throw "OUT_OF_BOUNDS": target.read target.size 1
  expect-throw "OUT_OF_BOUNDS": target.write target.size #[0]

test-validation:
  expect-throw "INVALID_ARGUMENT":
    i2c.RegisterTarget --sda=I2C-SDA --scl=I2C-SCL --address=ADDRESS --register-count=0
  expect-throw "INVALID_ARGUMENT":
    i2c.RegisterTarget --sda=I2C-SDA --scl=I2C-SCL --address=ADDRESS --register-address-size=3
  expect-throw "INVALID_ARGUMENT":
    i2c.RegisterTarget
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --register-address-size=2
        --receive-buffer-size=1
  expect-throw "INVALID_ARGUMENT":
    i2c.RegisterTarget --sda=I2C-SDA --scl=I2C-SCL --address=ADDRESS --register-count=257
  expect-throw "INVALID_ARGUMENT":
    i2c.RegisterTarget --sda=I2C-SDA --scl=I2C-SCL --address=0x80

make-target config/int -> i2c.RegisterTarget:
  if config == DEFAULT-CONFIG:
    return i2c.RegisterTarget
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --register-count=256
        --register-address-size=1
        --receive-buffer-size=64
        --pull-up
  if config == WIDE-CONFIG:
    return i2c.RegisterTarget
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=TEN-BIT-ADDRESS
        --address-size=10
        --register-count=512
        --register-address-size=2
        --receive-buffer-size=64
        --pull-up
  if config == SMALL-CONFIG:
    return i2c.RegisterTarget
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --register-count=32
        --register-address-size=1
        --receive-buffer-size=16
        --no-pull-up
  if config == BROADCAST-CONFIG:
    return i2c.RegisterTarget
        --sda=I2C-SDA
        --scl=I2C-SCL
        --address=ADDRESS
        --register-count=32
        --register-address-size=1
        --receive-buffer-size=32
        --pull-up
        --broadcast
  unreachable

set-registers port/uart.Port start/int data/ByteArray -> none:
  send-command port SET [encode-index start, data]
  expect-equals OK port.in.read-byte

expect-after port/uart.Port start/int expected/ByteArray [operation] -> none:
  send-command port EXPECT-AFTER [encode-index start, expected]
  operation.call
  send-byte port FINISH
  expect-equals OK port.in.read-byte

expect-dropped-after port/uart.Port start/int expected/ByteArray [operation] -> none:
  send-command port EXPECT-DROPPED-AFTER [encode-index start, expected]
  operation.call
  send-byte port FINISH
  expect-equals OK port.in.read-byte

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

encode-index index/int -> ByteArray:
  return #[index & 0xff, (index >> 8) & 0xff]

decode-index bytes/ByteArray -> int:
  return bytes[0] | (bytes[1] << 8)

make-data size/int seed/int -> ByteArray:
  return ByteArray size: (seed + 17 * it) & 0xff

wrapped data/ByteArray start/int count/int -> ByteArray:
  return ByteArray count: data[(start + it) % data.size]

wrapped-write original/ByteArray start/int update/ByteArray -> ByteArray:
  result := original.copy
  update.size.repeat: | i/int |
    result[(start + i) % result.size] = update[i]
  return result
