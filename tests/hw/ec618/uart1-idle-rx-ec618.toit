// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import uart

import .wiring as wiring

/**
EC618 half of the UART1 idle-RX test (device under test).

Hunts the "agent goes deaf" symptom seen on the quirky-plenty rig (its
  control lane is UART1): RX works right after boot and stops answering
  later. This reproduces the conditions on the modest-affair rig without
  any of quirky's confounds (relay power glitches, cold-boot ROM state):
  open UART1, let the ESP32 send a small marker every 5 s, and report the
  received-byte count once per 30 s phase. A healthy RX gains ~50+ bytes
  every phase; the failure signature is early phases gaining and a later
  phase flatlining. The UART0 agent (mini-jag) is the liveness control —
  the test keeps printing either way.

The ESP32 half sends markers for ~200 s, longer than this test's 5 x 30 s
  window.
*/

PHASES ::= 5
PHASE-MS ::= 30_000

main:
  port := uart.Port
      --rx=wiring.EC618-UART1-RX-PAD
      --tx=wiring.EC618-UART1-TX-PAD
      --baud-rate=115200
  try:
    check-idle-rx port
  finally:
    port.close

// Keep the reader and phase observer in one group: read failures propagate,
// and finishing the observation cancels and joins the pending read.
// The duck-typed port allows host fault injection against this same observer.
check-idle-rx port/any --phases/int=PHASES --phase/Duration=(Duration --ms=PHASE-MS):
  total := 0
  gains := []
  Task.group --required=1 [
    ::
      while data := port.in.read:
        total += data.size
      throw "uart1-idle-rx: FAIL reader closed during observation",
    ::
      previous := 0
      phases.repeat: |index/int|
        sleep phase
        gained := total - previous
        gains.add gained
        previous = total
        print "uart1-idle-rx: phase $index total=$total gained=$gained"
        if gained == 0:
          throw "uart1-idle-rx: FAIL no RX progress in phase $index",
  ]
  print "uart1-idle-rx: gains=$gains"
  print "uart1-idle-rx: PASS RX alive through all $phases phases"
