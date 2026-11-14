// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import pulse-counter
import uart

import .wiring as wiring

/** ESP32 frequency, duty, and static-level peer for pwm-rp2350.toit. */

TIMEOUT-MS ::= 10_000

main:
  port := uart.Port
      --tx=wiring.ESP32-UART-TX-PIN
      --rx=wiring.ESP32-UART-RX-PIN
      --baud-rate=115_200
  try:
    first := true
    while true:
      line := read-line port --timeout-ms=(first ? 60_000 : TIMEOUT-MS)
      first = false
      parts := line.split " "
      if parts == ["Q"]: return
      if parts.size != 2: throw "invalid PWM command '$line'"
      io := int.parse parts[1]
      if parts[0] == "F":
        measure-frequency port io
      else if parts[0] == "D":
        measure-duty port io
      else if parts[0] == "L":
        measure-level port io
      else:
        throw "invalid PWM command '$line'"
  finally:
    port.close

measure-frequency port/uart.Port io/int -> none:
  pin := gpio.Pin io --input --pull-down
  pin.close
  counter := pulse-counter.Unit io
  start := Time.monotonic-us
  sleep --ms=1_000
  edges := counter.value
  elapsed := Time.monotonic-us - start
  counter.close
  send-line port "F $edges $elapsed"

measure-duty port/uart.Port io/int -> none:
  pin := gpio.Pin io --input --pull-down
  deadline := Time.monotonic-us + 1_000_000
  high := 0
  total := 0
  while Time.monotonic-us < deadline:
    if pin.get == 1: high++
    total++
    if total & 0x3ff == 0: yield
  pin.close
  send-line port "D $(high * 1_000 / total)"

measure-level port/uart.Port io/int -> none:
  pin := gpio.Pin io --input --pull-down
  level := pin.get
  transitions := 0
  last := level
  total := 0
  deadline := Time.monotonic-us + 300_000
  while Time.monotonic-us < deadline:
    value := pin.get
    if value != last: transitions++
    last = value
    total++
    if total & 0x3ff == 0: yield
  pin.close
  send-line port "L $level $transitions"

send-line port/uart.Port line/string -> none:
  port.out.write "$line\n"
  port.out.flush

read-line port/uart.Port --timeout-ms/int -> string:
  return with-timeout --ms=timeout-ms:
    bytes := #[]
    while true:
      byte := port.in.read-byte
      if byte == '\n': return bytes.to-string-non-throwing.trim
      bytes += #[byte]
