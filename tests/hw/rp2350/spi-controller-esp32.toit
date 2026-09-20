// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-equals
import spi
import uart

import .wiring as wiring

/** ESP32 SPI controller peer for spi-target-rp2350.toit. */

main:
  control := uart.Port
      --tx=wiring.ESP32-UART-TX-PIN
      --rx=wiring.ESP32-UART-RX-PIN
      --baud-rate=115_200
  bus0 := spi.Bus --mosi=wiring.ESP32-SPI-CONTROLLER-MOSI-PIN
      --miso=wiring.ESP32-SPI-CONTROLLER-MISO-PIN
      --clock=wiring.ESP32-SPI-CONTROLLER-CLOCK-PIN
  bus1 := spi.Bus --mosi=wiring.ESP32-SPI1-CONTROLLER-MOSI-PIN
      --miso=wiring.ESP32-SPI1-CONTROLLER-MISO-PIN
      --clock=wiring.ESP32-SPI1-CONTROLLER-CLOCK-PIN
  try:
    while (read-line control) != "SPI-TARGET-TEST":
      // RP2350 reset can leave partial or NUL-prefixed UART input behind.
      continue
    send-line control "SYNC"
    while true:
      line := read-line control
      parts := line.split " "
      if parts[0] == "CASE":
        run-case control bus0 wiring.ESP32-SPI-CONTROLLER-CS-PIN parts
      else if parts[0] == "CASE1":
        run-case control bus1 wiring.ESP32-SPI1-CONTROLLER-CS-PIN parts
      else if parts[0] == "SEQUENCE":
        run-sequence control bus0
      else if parts[0] == "EARLY":
        run-early control bus0 (int.parse parts[1])
      else if parts[0] == "HOLD":
        run-held control bus0 (int.parse parts[1])
      else if parts[0] == "IDLE":
        send-line control "COMMAND IDLE"
        expect-line control "READY"
        send-line control "IDLE-DONE"
      else if parts[0] == "BUFFER":
        run-buffer control bus0
      else if parts[0] == "QUIT":
        send-line control "COMMAND QUIT"
        send-line control "BYE"
        return
      else:
        throw "invalid command '$line'"
  finally:
    bus1.close
    bus0.close
    control.close

run-case control/uart.Port bus/spi.Bus cs/int parts/List:
  mode := int.parse parts[1]
  transmit-lsb := parts[3] == "true"
  receive-lsb := parts[4] == "true"
  size := int.parse parts[5]
  device := bus.device
      --cs=cs
      --frequency=400_000
      --mode=mode
  try:
    send-line control "COMMAND $(parts[0])"
    expect-line control "READY"
    send-line control "CLOCKING"
    data := pattern size 23
    if receive-lsb: reverse-bits-in-place data
    device.transfer data --read
    expected := pattern size 7
    if transmit-lsb: reverse-bits-in-place expected
    expect-equals expected data
    send-line control "DONE"
  finally:
    device.close

run-sequence control/uart.Port bus/spi.Bus:
  device := bus.device
      --cs=wiring.ESP32-SPI-CONTROLLER-CS-PIN
      --frequency=400_000
      --mode=1
  try:
    send-line control "COMMAND SEQUENCE"
    sizes := [1, 3, 7, 9]
    sizes.size.repeat: | index/int |
      size := sizes[index]
      expect-line control "READY"
      send-line control "CLOCKING"
      data := pattern size (23 + index)
      device.transfer data --read
      expect-equals (pattern size (7 + index)) data
      send-line control "DONE"
  finally:
    device.close

run-early control/uart.Port bus/spi.Bus size/int:
  device := bus.device
      --cs=wiring.ESP32-SPI-CONTROLLER-CS-PIN
      --frequency=400_000
      --mode=1
  try:
    send-line control "COMMAND EARLY"
    expect-line control "READY"
    send-line control "CLOCKING"
    data := pattern size 23
    device.transfer data --read
    expect-equals (pattern 8 7)[..size] data
    send-line control "DONE"
  finally:
    device.close

run-held control/uart.Port bus/spi.Bus size/int:
  device := bus.device
      --cs=wiring.ESP32-SPI-CONTROLLER-CS-PIN
      --frequency=100_000
      --mode=1
  try:
    send-line control "COMMAND HOLD"
    expect-line control "READY"
    send-line control "CLOCKING"
    device.with-reserved-bus:
      data := pattern size 23
      device.transfer data --read --keep-cs-active
      expect-equals (pattern size 7) data
      expect-line control "FULL"
      // This byte is deliberately beyond the mounted target buffer. It only
      // releases CS and must not leak into a later target transaction.
      device.write #[0]
    send-line control "RELEASED"
  finally:
    device.close

run-buffer control/uart.Port bus/spi.Bus:
  device := bus.device
      --cs=wiring.ESP32-SPI-CONTROLLER-CS-PIN
      --frequency=400_000
      --mode=3
  try:
    send-line control "COMMAND BUFFER"
    expect-line control "READY"
    send-line control "CLOCKING"
    exchange device (pattern 3 23) 3
    exchange device (pattern 12 41) 8
    exchange device (pattern 4 59) 4
    send-line control "DONE"
  finally:
    device.close

exchange device/spi.Device outgoing/ByteArray expected-response-size/int:
  incoming := outgoing.copy
  device.transfer incoming --read
  expect-equals (pattern 8 7)[..expected-response-size]
      (incoming[..expected-response-size])

reverse-bits-in-place bytes/ByteArray:
  bytes.size.repeat: | i/int |
    value := bytes[i]
    reversed := 0
    8.repeat:
      reversed = (reversed << 1) | (value & 1)
      value >>= 1
    bytes[i] = reversed

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 31 + seed) & 0xff

send-line port/uart.Port line/string:
  port.out.write "$line\n"
  port.out.flush

expect-line port/uart.Port expected/string:
  actual := read-line port
  if actual != expected: throw "expected '$expected', got '$actual'"

read-line port/uart.Port -> string:
  return with-timeout --ms=60_000:
    bytes := #[]
    while true:
      byte := port.in.read-byte
      if byte == '\n': return bytes.to-string-non-throwing.trim
      bytes += #[byte]
