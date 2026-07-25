// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

import .wiring as wiring

/**
EC618 half of the consolidated dev-board GPIO test.

The ESP32 helper and this program coordinate every phase over a UART. UART1 is
  the initial control lane, so UART2's pads can be tested as GPIO; both sides
  then move to UART2 before testing UART1's pads.

For every ordinary dev-board GPIO net, this program:

1. Drives a pulse train while the ESP32 observes every safe connected input.
2. Configures the EC618 pad as input before asking the ESP32 to drive low/high.

PAD42's ESP32 connection controls the loaded sensor-power path and is not
  bidirectionally observable as logic. Its input direction is covered here; its
  output direction is covered by `gpio-aon-output-ec618.toit`, which proves that
  it powers the BMP280 across two cycles. After the PAD42 input phase, this test
  holds the sensor rail high so GPIO tests on its SDA/SCL wires cannot
  parasitically power the sensor and appear as false cross-net edges.

Dedicated pads verify the two supported pull paths after the ESP32 has driven
  the opposite level and acknowledged its release: wake-domain PAD42 for
  pull-down and regular PAD34 for pull-up. No phase relies on synchronized time
  slots, floating-line reads, or simultaneous push-pull outputs.
*/

CONTROL-BAUD ::= 9600
CONTROL-TIMEOUT-MS ::= 10_000
PULSES ::= 12
PULSE-HALF ::= Duration --ms=15
SETTLE ::= Duration --ms=30

class Control:
  id/int
  tx/gpio.Pin
  rx/gpio.Pin
  port/uart.Port
  pending_/ByteArray := #[]
  last-matched_/string? := null

  constructor .id:
    tx-pad := id == 1 ? wiring.EC618-UART1-TX-PAD : wiring.EC618-UART2-TX-PAD
    rx-pad := id == 1 ? wiring.EC618-UART1-RX-PAD : wiring.EC618-UART2-RX-PAD
    tx = gpio.Pin tx-pad
    rx = gpio.Pin rx-pad
    port = uart.Port --tx=tx --rx=rx --baud-rate=CONTROL-BAUD
    print "gpio-map-ec618: opened UART$id control (TX PAD$tx-pad / RX PAD$rx-pad)"

  send line/string -> none:
    port.out.write "$line\n"
    port.out.flush

  read-line -> string:
    with-timeout --ms=CONTROL-TIMEOUT-MS:
      while true:
        newline := pending_.index-of '\n'
        if newline >= 0:
          result := pending_[..newline].to-string-non-throwing.trim
          pending_ = pending_[newline + 1 ..]
          return result
        chunk := port.in.read
        if not chunk: throw "control UART$id closed"
        pending_ += chunk
    unreachable

  expect expected/string -> none:
    8.repeat:
      line := read-line
      if line == expected:
        last-matched_ = line
        return
      if line == last-matched_: continue.repeat
      print "gpio-map-ec618: ignoring control line '$line' while waiting for '$expected'"
    throw "expected control reply '$expected'"

  close -> none:
    port.close
    rx.close
    tx.close

main:
  control := Control 1
  // Terminate any UART1 boot-ROM residue in the helper's line buffer.
  control.send ""
  control.send "HELLO 1"
  control.expect "READY 1"

  sensor-power/gpio.Pin? := null
  try:
    wiring.GPIO-TEST-WIRES.do: | wire/List |
      pad/int := wire[0]
      direct/List := wire[1]
      expected/List := wire.size == 3 ? wire[2] : direct
      if pad == wiring.EC618-UART1-TX-PAD:
        control = switch-control control 2
      if pad != wiring.EC618-GPIO22-PAD:
        test-output control pad direct expected
      test-input control pad
      if pad == wiring.EC618-GPIO22-PAD:
        sensor-power = gpio.Pin pad --output --value=1

    if sensor-power:
      sensor-power.close
      sensor-power = null
    down-pad := wiring.EC618-GPIO-PULL-DOWN-TEST-PAD
    down-result := test-pulls control down-pad
    if not down-result[0]: throw "PAD$down-pad pull-down did not settle low"

    up-pad := wiring.EC618-GPIO-PULL-UP-TEST-PAD
    up-result := test-pulls control up-pad
    if not up-result[1]: throw "PAD$up-pad pull-up did not settle high"
    control.send "Q"
    control.expect "BYE"
  finally:
    if sensor-power: sensor-power.close
    control.close
  print "gpio-map-ec618: PASS ordinary GPIO nets both ways, PAD42 input, pull-up, and pull-down"

switch-control old/Control id/int -> Control:
  replacement := Control id
  old.send "SWITCH $id"
  old.expect "SWITCHING $id"
  replacement.expect "HELLO $id"
  replacement.send "READY $id"
  replacement.expect "ACTIVE $id"
  old.close
  print "gpio-map-ec618: control moved to UART$id"
  return replacement

test-output control/Control pad/int direct/List expected/List -> none:
  control.send "OBSERVE $pad"
  control.expect "READY-TO-OBSERVE $pad"

  pin := gpio.Pin pad
  try:
    pin.configure --output --value=0
    PULSES.repeat:
      pin.set 1
      sleep PULSE-HALF
      pin.set 0
      sleep PULSE-HALF
  finally:
    pin.close

  control.send "OBSERVE-DONE $pad"
  control.expect "OBSERVED $pad $expected"
  print "gpio-map-ec618: PAD$pad output direct IO$direct, observed IO$expected"

test-input control/Control pad/int -> none:
  pin := gpio.Pin pad
  try:
    pin.configure --input
    [0, 1].do: | level/int |
      control.send "DRIVE $pad $level"
      control.expect "DRIVEN $pad $level"
      sleep SETTLE
      if pin.get != level:
        throw "PAD$pad read $(pin.get) while ESP32 drove $level"
    control.send "RELEASE $pad"
    control.expect "RELEASED $pad"
  finally:
    pin.close
  print "gpio-map-ec618: PAD$pad input read ESP32 low/high"

test-pulls control/Control pad/int -> List:
  pin := gpio.Pin pad
  down-ok := false
  up-ok := false
  try:
    pin.configure --input

    // Establish a high level, then release before enabling the pull-down.
    control.send "DRIVE $pad 1"
    control.expect "DRIVEN $pad 1"
    sleep SETTLE
    if pin.get != 1: throw "PAD$pad did not read the driven high level"
    control.send "RELEASE $pad"
    control.expect "RELEASED $pad"
    pin.set-pull --down
    sleep (pad == wiring.EC618-GPIO22-PAD ? Duration --s=10 : SETTLE)
    down-ok = pin.get == 0

    // Establish a low level, then release before enabling the pull-up.
    control.send "DRIVE $pad 0"
    control.expect "DRIVEN $pad 0"
    sleep SETTLE
    if pin.get != 0: throw "PAD$pad did not read the driven low level"
    control.send "RELEASE $pad"
    control.expect "RELEASED $pad"
    pin.set-pull --up
    sleep (pad == wiring.EC618-GPIO22-PAD ? Duration --ms=500 : SETTLE)
    up-ok = pin.get == 1
    pin.set-pull --off
  finally:
    pin.close
  print "gpio-map-ec618: PAD$pad pull-down=$(down-ok ? "ok" : "unavailable") pull-up=$(up-ok ? "ok" : "unavailable")"
  return [down-ok, up-ok]
