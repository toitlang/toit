// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show expect-equals expect-throw
import gpio
import gpio.pwm show Pwm
import uart

/**
Exercises numeric-GP PWM on the RP2350B and measures it with the ESP32 peer.

The rig connects GP6 (slice 3A) to ESP32 IO18 and GP7 (slice 3B) to IO23.
UART0 on GP16/GP1 is the command lane. Start pwm-esp32.toit first.
*/

PWM-A ::= 6
PWM-B ::= 7
PWM-A-ALIAS ::= 22  // Slice 3A, like GP6, but not wired to the peer.
ESP-PWM-A ::= 18
ESP-PWM-B ::= 23
UART-TX ::= 16
UART-RX ::= 1
TIMEOUT-MS ::= 10_000

failures := []

main:
  control := uart.Port --tx=UART-TX --rx=UART-RX --baud-rate=115_200
  try:
    expect-level control ESP-PWM-A 0 "initial-a"
    expect-level control ESP-PWM-B 0 "initial-b"
    test-contract
    test-duty control
    test-frequency control
    test-shared-slice control
    send-line control "Q"
  finally:
    control.close

  if not failures.is-empty:
    print "pwm-rp2350: FAIL $failures"
    throw "PWM test failed: $failures"
  print "pwm-rp2350: PASS"

test-contract -> none:
  expect-throw "INVALID_ARGUMENT": Pwm --frequency=0
  expect-throw "INVALID_ARGUMENT": Pwm --frequency=2_000 --max-frequency=1_000
  expect-throw "INVALID_ARGUMENT": Pwm --frequency=40_000_001
  expect-throw "INVALID_ARGUMENT": Pwm --frequency=1 --max-frequency=40_000_000

  restricted := Pwm --frequency=1_000
  try:
    expect-throw "PERMISSION_DENIED": restricted.start 0
    expect-throw "INVALID_ARGUMENT": restricted.start -2
    expect-throw "OUT_OF_RANGE": restricted.start 48
    legacy := gpio.Pin 34 --input
    try:
      expect-throw "INVALID_ARGUMENT": restricted.start legacy  // @no-warn
    finally:
      legacy.close
  finally:
    restricted.close

  occupied := gpio.Pin PWM-A --input
  generator := Pwm --frequency=1_000 --max-frequency=8_000
  try:
    expect-throw "ALREADY_IN_USE": generator.start PWM-A
  finally:
    occupied.close

  first := generator.start PWM-A --duty-factor=0.5
  other := Pwm --frequency=1_000
  try:
    expect-throw "ALREADY_IN_USE": gpio.Pin PWM-A --input
    // A second generator cannot change the divider of an owned slice.
    expect-throw "ALREADY_IN_USE": other.start PWM-B
    // GP22 aliases GP6's hardware channel and cannot have a separate duty.
    expect-throw "ALREADY_IN_USE": generator.start PWM-A-ALIAS
    alias-pin := gpio.Pin PWM-A-ALIAS --input
    alias-pin.close
  finally:
    other.close
    first.close
    generator.close

  // Closing the last channel returns both the pin and slice lease.
  reopened := Pwm --frequency=1_000
  channel := reopened.start PWM-B
  channel.close
  reopened.close
  pin := gpio.Pin PWM-B --input
  pin.close
  print "pwm-rp2350: numeric pin and lease contract ok"

test-duty control/uart.Port -> none:
  generator := Pwm --frequency=100
  channel := generator.start PWM-A --duty-factor=0.25
  try:
    expect-equals 0.25 channel.duty-factor
    expect-duty control ESP-PWM-A 250 "duty-0.25"
    channel.set-duty-factor 0.5
    expect-equals 0.5 channel.duty-factor
    expect-duty control ESP-PWM-A 500 "duty-0.50"
    channel.set-duty-factor 0.75
    expect-duty control ESP-PWM-A 750 "duty-0.75"

    // The public API clamps duty factors to [0.0..1.0].
    channel.set-duty-factor -1
    expect-equals 0.0 channel.duty-factor
    expect-level control ESP-PWM-A 0 "duty-clamped-low"
    channel.set-duty-factor 2
    expect-equals 1.0 channel.duty-factor
    expect-level control ESP-PWM-A 1 "duty-clamped-high"
    channel.set-duty-factor 0.5
    expect-duty control ESP-PWM-A 500 "duty-recover"
  finally:
    channel.close
    generator.close
  expect-level control ESP-PWM-A 0 "duty-close"

test-frequency control/uart.Port -> none:
  generator := Pwm --frequency=1_000 --max-frequency=8_000
  channel := generator.start PWM-A --duty-factor=0.5
  try:
    expect-hz control ESP-PWM-A 1_000 "frequency-1k"
    generator.frequency = 2_000
    expect-equals 2_000 generator.frequency
    expect-hz control ESP-PWM-A 2_000 "frequency-2k"
    expect-throw "INVALID_ARGUMENT": generator.frequency = 8_001
    expect-throw "INVALID_ARGUMENT": generator.frequency = 0
    expect-hz control ESP-PWM-A 2_000 "frequency-after-rejection"
  finally:
    channel.close
    generator.close

test-shared-slice control/uart.Port -> none:
  generator := Pwm --frequency=1_000 --max-frequency=8_000
  channel-a := generator.start PWM-A --duty-factor=0.5
  channel-b := generator.start PWM-B --duty-factor=0.25
  try:
    expect-hz control ESP-PWM-A 1_000 "shared-slice-a"
    expect-hz control ESP-PWM-B 1_000 "shared-slice-b"
    generator.frequency = 2_000
    expect-hz control ESP-PWM-A 2_000 "shared-slice-a-update"
    expect-hz control ESP-PWM-B 2_000 "shared-slice-b-update"

    channel-a.close
    expect-level control ESP-PWM-A 0 "shared-close-a"
    expect-hz control ESP-PWM-B 2_000 "shared-b-still-running"
  finally:
    channel-a.close
    generator.close  // Also closes channel B.
  expect-level control ESP-PWM-B 0 "shared-group-close-b"

exchange control/uart.Port command/string -> List:
  send-line control command
  return read-reply control

send-line control/uart.Port line/string -> none:
  control.out.write "$line\n"
  control.out.flush

read-reply control/uart.Port -> List:
  return with-timeout --ms=TIMEOUT-MS:
    bytes := #[]
    while true:
      byte := control.in.read-byte
      if byte == '\n': return bytes.to-string-non-throwing.trim.split " "
      bytes += #[byte]

expect-hz control/uart.Port io/int hz/int label/string -> none:
  reply := exchange control "F $io"
  edges := int.parse reply[1]
  elapsed-us := int.parse reply[2]
  measured := edges * 1_000_000.0 / elapsed-us
  ok := measured > hz * 0.9 and measured < hz * 1.1
  print "pwm-rp2350: $label $(ok ? "ok" : "FAIL") ($(measured.to-int) Hz, want $hz)"
  if not ok: failures.add label

expect-duty control/uart.Port io/int permille/int label/string -> none:
  reply := exchange control "D $io"
  measured := int.parse reply[1]
  ok := (measured - permille).abs <= 60
  print "pwm-rp2350: $label $(ok ? "ok" : "FAIL") ($(measured)‰, want $permille‰)"
  if not ok: failures.add label

expect-level control/uart.Port io/int level/int label/string -> none:
  reply := exchange control "L $io"
  got-level := int.parse reply[1]
  edges := int.parse reply[2]
  ok := got-level == level and edges == 0
  print "pwm-rp2350: $label $(ok ? "ok" : "FAIL") (level $got-level, edges $edges)"
  if not ok: failures.add label
