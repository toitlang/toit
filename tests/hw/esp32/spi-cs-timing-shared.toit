// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import rmt
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

READY ::= 0xa1
DONE ::= 0xa2
CLOSE ::= 0xa3

FREQUENCY ::= 100_000
CYCLE-US ::= 1_000_000 / FREQUENCY
TRANSFER ::= #[0x12, 0x34, 0x56, 0x78]

main-board1:
  run-test: test-board1

test-board1:
  port := uart.Port --rx=RX1 --tx=TX1 --baud-rate=115_200
  expect-equals READY port.in.read-byte
  bus := spi.Bus --clock=SCLK --mosi=MOSI

  baseline := measure port bus 0 0
  print "SPI CS timing: setup=0 hold=0 low=$(baseline)us"

  16.repeat: | index/int |
    check-timing port bus baseline index + 1 0

  hold-max := system.architecture == system.ARCHITECTURE-ESP32 ? 15 : 16
  hold-max.repeat: | index/int |
    check-timing port bus baseline 0 index + 1

  if system.architecture == system.ARCHITECTURE-ESP32:
    expect-throw "OUT_OF_RANGE":
      bus.device
          --cs=CS
          --frequency=FREQUENCY
          --cs-hold-cycles=16

  port.out.write #[CLOSE] --flush
  expect-equals DONE port.in.read-byte
  bus.close
  port.close

check-timing port/uart.Port bus/spi.Bus baseline/int setup/int hold/int -> none:
  measured := measure port bus setup hold
  print "SPI CS timing: setup=$setup hold=$hold low=$(measured)us"

  // ESP-IDF maps a requested hold of zero to one cycle because the hardware
  // needs that minimum. All other setup/hold values contribute one full SPI
  // clock cycle each.
  effective-hold := max 1 hold
  expected-delta := (setup + effective-hold - 1) * CYCLE-US
  expect (measured - baseline - expected-delta).abs <= 3

measure port/uart.Port bus/spi.Bus setup/int hold/int -> int:
  port.out.write #[setup, hold] --flush
  expect-equals READY port.in.read-byte
  device := bus.device
      --cs=CS
      --frequency=FREQUENCY
      --cs-setup-cycles=setup
      --cs-hold-cycles=hold
  device.write TRANSFER
  device.close
  expect-equals DONE port.in.read-byte
  return port.in.little-endian.read-uint32

main-board2:
  run-test --background: test-board2

test-board2:
  port := uart.Port --rx=RX2 --tx=TX2 --baud-rate=115_200
  port.out.write #[READY] --flush

  while true:
    setup := port.in.read-byte
    if setup == CLOSE:
      port.out.write #[DONE] --flush
      port.close
      return
    hold := port.in.read-byte

    cs-probe := rmt.In CS --resolution=1_000_000 --memory-blocks=2
    clock-probe := rmt.In SCLK --resolution=1_000_000 --memory-blocks=2
    try:
      cs-probe.start-reading --max-ns=10_000_000
      clock-probe.start-reading --max-ns=10_000_000
      port.out.write #[READY] --flush

      cs-signals := cs-probe.wait-for-data
      clock-signals := clock-probe.wait-for-data
      cs-low-us := longest-signal-us cs-signals 0

      high-count := 0
      clock-signals.size.repeat: | i/int |
        duration-us := (clock-signals.ns-duration i) / 1_000
        if (clock-signals.level i) == 1 and duration-us != 0:
          if 3 <= duration-us <= 7:
            high-count++
          else:
            print "Ignoring non-clock SCLK-high signal: $(duration-us)us"
      expect-equals TRANSFER.size * 8 high-count
      expect cs-low-us >= TRANSFER.size * 8 * CYCLE-US
      expect cs-low-us < 1_000

      port.out.write #[DONE] --flush
      port.out.little-endian.write-uint32 cs-low-us
      port.out.flush
    finally:
      cs-probe.close
      clock-probe.close

longest-signal-us signals/rmt.Signals level/int -> int:
  result := 0
  signals.size.repeat: | i/int |
    if (signals.level i) == level:
      result = max result ((signals.ns-duration i) / 1_000)
  return result
