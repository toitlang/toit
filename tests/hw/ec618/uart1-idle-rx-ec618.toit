// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import uart

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

Wiring (mini-jag control-lane wiring, as used by uart2-gapfree):
  ESP32 IO16 -> EC618 PAD33 (UART1 RX); EC618 PAD34 -> ESP32 IO4.
  gpio.Pin numbers are PAD numbers on EC618.

Run the ESP32 half (uart1-idle-rx-esp32.toit) FIRST; it sends markers
  for ~200 s, longer than this test's 5 x 30 s window.
*/

PHASES ::= 5
PHASE-MS ::= 30_000

main:
  port := uart.Port --rx=(gpio.Pin 33) --tx=(gpio.Pin 34) --baud-rate=115200
  total := 0
  reader := task::
    catch:  // Closing the port unblocks the read with an exception.
      while data := port.in.read:
        total += data.size

  counts := []
  PHASES.repeat: | phase/int |
    sleep --ms=PHASE-MS
    counts.add total
    print "uart1-idle-rx: phase $phase total=$total"

  port.close

  // Per-phase gains: the ESP32 sends ~6 markers (~54 bytes) per phase.
  gains := []
  PHASES.repeat: | i/int |
    gains.add (counts[i] - (i == 0 ? 0 : counts[i - 1]))
  print "uart1-idle-rx: gains=$gains"

  if counts.last == 0:
    print "uart1-idle-rx: FAIL nothing received at all (helper running? wiring?)"
    exit 1
  if gains.last == 0:
    print "uart1-idle-rx: FAIL RX went deaf (early phases received, later flatlined) — reproduced"
    exit 1
  print "uart1-idle-rx: PASS RX alive through all $PHASES phases"
