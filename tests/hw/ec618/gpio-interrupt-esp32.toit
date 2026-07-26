// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio

import .framed-control show FramedChannel
import .uart-rig as rig
import .wiring as wiring

/**
ESP32 half of the GPIO-interrupt test: a pulse generator.

Listens on the framed control lane for "P <count> <phase-ms>" and then drives that many clean pulses on IO27. "Q" quits. All assertions run on the EC618.
*/

main:
  control-owner := rig.esp32-uart 1 115200
  control := FramedChannel control-owner.port
  out := gpio.Pin wiring.ESP32-GPIO11-PIN --output --value=0
  connected := false
  print "gpio-interrupt-esp32: ready (control IO$(wiring.ESP32-UART1-RX-PIN); pulses on IO$(wiring.ESP32-GPIO11-PIN))"

  try:
    while true:
      message := control.receive --timeout-ms=(connected ? 15_000 : 120_000)
      if message == "HELLO":
        connected = true
        control.send "READY"
        continue
      if message == "Q":
        control.send "BYE"
        return

      parts := message.split " "
      if parts.size != 3 or parts[0] != "P":
        throw "unexpected command '$message'"
      count := int.parse parts[1]
      phase-ms := int.parse parts[2]
      if count <= 0 or phase-ms <= 0: throw "invalid pulse command '$message'"
      control.send "ARMED"
      sleep --ms=20  // Let the EC618 enter its first wait-for.
      count.repeat:
        out.set 1
        sleep --ms=phase-ms
        out.set 0
        sleep --ms=phase-ms
      control.send "DONE"
      print "gpio-interrupt-esp32: drove $count pulses at $phase-ms ms/phase"
  finally:
    out.close
    control-owner.close
