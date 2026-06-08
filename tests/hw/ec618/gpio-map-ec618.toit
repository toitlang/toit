// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the rig connectivity-map test (device under test).

Drives a set of EC618 GPIO controller bits one at a time, each as a square wave
for a fixed time slot, so the ESP32 half (gpio-map-esp32.toit) can see which of
its input pins moves in each slot and print the EC618-bit <-> ESP32-pin map. This
implements the "always gpio-toggle a wire to confirm connectivity" safety step at
rig scale, and resolves the "to verify" rows in docs/ec618-hw-tests.md.

Only EC618-drives -> ESP32-reads is used (1.8 V -> 3.3 V, the safe direction; the
ESP32 never drives, so there is no short-circuit risk regardless of how the rig
is wired). The bit set is deliberately conservative: the UART0 console pads
(bits 12-15) are excluded so the mini-jag control channel keeps working, and the
low pads (bits 2-5, possibly flash/special) are excluded for safety. The included
bits are known-safe GPIO: 11 (PAD26, already confirmed), 10 (UART2 RX pad), and
16-19 (UART1 pads, not the console).

A short sync burst on $SYNC-BIT (GPIO11 -> the confirmed ESP32 IO27 wire) lets the
ESP32 lock onto t0 before the per-slot sequence; everything after is fixed timing.

WARNING (2026-06-08): an earlier version of this test (which also re-drove GPIO11
in a slot) crashed the EC618 on container teardown — a CLOSED exception in the
shared GPIO service brought the whole VM down (EXIT_DONE), and the firmware then
deep-slept with no wakeup timer, bricking the board until a physical power-cycle
(the watchdogs are gated while asleep). Run this ONLY on firmware built with
CONFIG_TOIT_EC618_RESET_ON_VM_EXIT=1, which turns such a VM exit into a reboot
that self-recovers. The underlying GPIO-service teardown crash is a separate
robustness TODO — see docs/ec618-hw-tests.md.

Run via the mini-jag tester (start gpio-map-esp32.toit on the ESP32 first):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/gpio-map-ec618.toit
*/

import gpio
import ec618 show Ec618

// EC618 controller bits to map (driven on their primary pad). GPIO11 is NOT in
// the slot list — it is exercised by the sync burst (and re-opening the same
// controller bit in a slot was implicated in the teardown crash; see the header).
BITS ::= [10, 16, 17, 18, 19]
SYNC-BIT ::= 11                  // PAD26 -> ESP32 IO27, the confirmed anchor wire.
SYNC-PULSES ::= 6
SYNC-HALF ::= Duration --ms=80   // 6.25 Hz burst, distinct from the 25 Hz slot wave.
LEAD-IN ::= Duration --ms=600    // Quiet gap after the sync burst, before slot 0.
SLOT ::= Duration --s=3
SLOT-HALF ::= Duration --ms=20   // 25 Hz square wave inside a slot.

drive-square pin/gpio.Pin half/Duration duration/Duration -> none:
  deadline := Time.monotonic-us + duration.in-us
  v := 0
  while Time.monotonic-us < deadline:
    v = 1 - v
    pin.set v
    sleep half
  pin.set 0

main:
  // Sync burst on the anchor wire so the ESP32 can lock t0.
  sync := Ec618.gpio SYNC-BIT
  sync.configure --output --value=0
  print "gpio-map-ec618: sync burst on GPIO$SYNC-BIT ($SYNC-PULSES pulses)"
  drive-square sync SYNC-HALF (Duration --ms=(SYNC-PULSES * 2 * SYNC-HALF.in-ms))
  sync.close
  sleep LEAD-IN

  // Per-slot: drive each bit as a 25 Hz square wave for SLOT, in order.
  BITS.do: | bit/int |
    pin := Ec618.gpio bit
    pin.configure --output --value=0
    print "gpio-map-ec618: slot driving GPIO$bit"
    drive-square pin SLOT-HALF SLOT
    pin.close
  print "gpio-map-ec618: done"
