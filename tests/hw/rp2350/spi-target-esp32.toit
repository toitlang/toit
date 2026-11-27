// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-equals
import spi
import uart

import .wiring as wiring

/** ESP32 hardware SPI target peer for spi-controller-rp2350.toit. */

TIMEOUT-MS ::= 60_000

main:
  control := uart.Port
      --tx=wiring.ESP32-UART-TX-PIN
      --rx=wiring.ESP32-UART-RX-PIN
      --baud-rate=115_200
  print "spi-target-esp32: waiting for RP2350"
  try:
    while true:
      line := read-line control
      parts := line.split " "
      command := parts[0]
      if command == "HELLO" and parts.size == 1:
        send-line control "READY"
      else if command == "ARM" and parts.size == 4:
        mode := int.parse parts[1]
        prefix := int.parse parts[2]
        size := int.parse parts[3]
        run-transfer control mode prefix size
      else if command == "QUIT" and parts.size == 1:
        send-line control "BYE"
        return
      else:
        throw "invalid SPI test command '$line'"
  finally:
    control.close

run-transfer control/uart.Port mode/int prefix/int size/int -> none:
  total := prefix + size
  target := spi.Target
      --mosi=23
      --miso=19
      --clock=18
      --cs=27
      --mode=mode
      --max-transfer-size=total
      --dma=false
  try:
    received := with-timeout --ms=5_000:
      target.transfer (pattern total 7)
          --receive-size=total
          --when-armed=(: send-line control "READY")
    expected := (prefix-bytes prefix) + (pattern size 23)
    error := catch: expect-equals expected received
    send-line control (error ? "ERROR $error" : "DONE")
  finally:
    target.close

prefix-bytes prefix/int -> ByteArray:
  if prefix == 0: return #[]
  if prefix == 1: return #[0x0b]
  if prefix == 3: return #[0xa5, 0x12, 0x34]
  throw "invalid prefix size $prefix"

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 31 + seed) & 0xff

send-line port/uart.Port line/string -> none:
  port.out.write "$line\n"
  port.out.flush

read-line port/uart.Port -> string:
  return with-timeout --ms=TIMEOUT-MS:
    bytes := #[]
    while true:
      byte := port.in.read-byte
      if byte == '\n': return bytes.to-string-non-throwing.trim
      bytes += #[byte]
