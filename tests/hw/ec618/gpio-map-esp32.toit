// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import monitor
import uart

import .framed-control show FramedChannel
import .wiring as wiring

/**
ESP32 half of the consolidated dev-board GPIO test.

Every phase is commanded by the EC618 over a UART and acknowledged before
  either side changes a pin's direction. UART1 is used while UART2's pads are
  tested; the `SWITCH 2` handshake closes the old observers/control pins on
  both boards before UART2 opens and UART1's pads become test GPIOs.
*/

CONTROL-BAUD ::= 9600
CONTROL-TIMEOUT-MS ::= 15_000
STARTUP-TIMEOUT-MS ::= 120_000
SAMPLE ::= Duration --ms=1
MIN-EDGES ::= 8

class Control:
  id/int
  port/uart.Port
  channel/FramedChannel

  constructor .id:
    tx-num := id == 1 ? wiring.ESP32-UART1-TX-PIN : wiring.ESP32-UART2-TX-PIN
    rx-num := id == 1 ? wiring.ESP32-UART1-RX-PIN : wiring.ESP32-UART2-RX-PIN
    port = uart.Port --tx=tx-num --rx=rx-num --baud-rate=CONTROL-BAUD
    channel = FramedChannel port

  send line/string -> none:
    channel.send line

  read-line --timeout-ms/int=CONTROL-TIMEOUT-MS -> string:
    return channel.receive --timeout-ms=timeout-ms

  close -> none:
    port.close

main:
  control := Control 1
  pins := open-observers 1
  connected := false
  try:
    while true:
      line := control.read-line
          --timeout-ms=(connected ? CONTROL-TIMEOUT-MS : STARTUP-TIMEOUT-MS)
      if line == "": continue
      parts := line.split " "
      command := parts[0]

      if command == "HELLO" and parts.size == 2:
        control.send "READY $parts[1]"
        connected = true
      else if command == "OBSERVE" and parts.size == 2:
        pad := int.parse parts[1]
        observe control pins pad
      else if command == "DRIVE" and parts.size == 3:
        pad := int.parse parts[1]
        level := int.parse parts[2]
        drive control pins pad level
      else if command == "RELEASE" and parts.size == 2:
        pad := int.parse parts[1]
        release control pins pad
      else if command == "SWITCH" and parts.size == 2:
        id := int.parse parts[1]
        pins.do: | _ pin/gpio.Pin | pin.close
        pins = {:}
        replacement := Control id
        control.send "SWITCHING $id"
        replacement.send "HELLO $id"
        if replacement.read-line != "READY $id":
          throw "control-lane switch was not acknowledged"
        control.close
        control = replacement
        pins = open-observers id
        control.send "ACTIVE $id"
        print "gpio-map-esp32: control moved to UART$id"
      else if command == "Q":
        control.send "BYE"
        return
  finally:
    pins.do: | _ pin/gpio.Pin | pin.close
    control.close
    print "gpio-map-esp32: done"

open-observers control-id/int -> Map:
  excluded := control-id == 1
      ? [wiring.ESP32-UART1-TX-PIN, wiring.ESP32-UART1-RX-PIN]
      : wiring.ESP32-EC618-PAD26-NET-PINS + wiring.ESP32-EC618-PAD25-NET-PINS
  pins := {:}
  wiring.ESP32-GPIO-OBSERVATION-PINS.do: | num/int |
    if not excluded.contains num:
      pins[num] = gpio.Pin num --input --pull-down
  return pins

wire-for pad/int -> List:
  wiring.GPIO-TEST-WIRES.do: | wire/List |
    if wire[0] == pad: return wire
  throw "unknown EC618 pad $pad"

observe control/Control pins/Map pad/int -> none:
  // Re-establish deterministic low baselines after any earlier drive phase.
  pins.do: | _ pin/gpio.Pin |
    pin.configure --input
    pin.set-pull --down

  stop := false
  started := monitor.Latch
  finished := monitor.Latch
  counts := {:}
  previous := {:}
  pins.do: | num/int pin/gpio.Pin |
    counts[num] = 0
    previous[num] = pin.get

  task::
    started.set true
    while not stop:
      pins.do: | num/int pin/gpio.Pin |
        level := pin.get
        if level != previous[num]:
          counts[num] = counts[num] + 1
          previous[num] = level
      sleep SAMPLE
    observed := wiring.ESP32-GPIO-OBSERVATION-PINS.filter: | num/int |
      counts.contains num and counts[num] >= MIN-EDGES
    finished.set observed

  started.get
  control.send "READY-TO-OBSERVE $pad"
  done := control.read-line
  if done != "OBSERVE-DONE $pad": throw "expected OBSERVE-DONE $pad, got '$done'"
  stop = true
  observed/List := finished.get
  control.send "OBSERVED $pad $observed"
  print "gpio-map-esp32: PAD$pad observed on IO$observed"

drive control/Control pins/Map pad/int level/int -> none:
  if level != 0 and level != 1: throw "invalid drive level $level"
  wire := wire-for pad
  num/int := wire[1][0]
  pin/gpio.Pin? := pins[num]
  if not pin: throw "ESP32 IO$num is unavailable while UART$control.id is active"
  pin.set-pull --off
  pin.configure --output --value=level
  control.send "DRIVEN $pad $level"

release control/Control pins/Map pad/int -> none:
  wire := wire-for pad
  num/int := wire[1][0]
  pin/gpio.Pin? := pins[num]
  if not pin: throw "ESP32 IO$num is unavailable while UART$control.id is active"
  pin.configure --input
  pin.set-pull --off
  control.send "RELEASED $pad"
