// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import ec618 show Ec618

/**
EC618 half of the rig connectivity-map test (device under test).

Drives every GPIO-capable EC618 PAD one at a time, each as a square wave for a
  fixed time slot, so the ESP32 half (gpio-map-esp32.toit) can see which of its
  input pins moves in each slot and print the complete PAD <-> ESP32-pin map.
  This implements the "always gpio-toggle a wire to confirm connectivity" safety
  step at rig scale, answers any "which pad is this module pin?" question in one
  run, and resolves the "to verify" rows in docs/ec618-hw-tests.md.

Only EC618-drives -> ESP32-reads is used (the safe direction; the ESP32 never
  drives, so there is no short-circuit risk regardless of how the rig is wired).
  Excluded pads: 29/30 (UART0 = the console/mini-jag channel) and 26 (the sync
  anchor, exercised by the burst itself).

A short sync burst on PAD26 (-> the confirmed ESP32 IO27 wire) lets the ESP32
  lock onto t0 before the per-slot sequence; everything after is fixed timing.

Run via the mini-jag tester (start gpio-map-esp32.toit on the ESP32 first):

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/gpio-map-ec618.toit
```
*/

// EC618 PADs to map, one per slot. PAD26 is NOT in the slot list — it is
// exercised by the sync burst (and re-opening the same controller bit in a
// slot was implicated in the teardown crash; see the header). 29/30 are the
// console. Pads without a GPIO controller bit can't be driven this way and
// are not listed (the gpio.Pin constructor would reject them).
PADS ::= [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 31, 32, 33, 34, 35, 36, 37, 40, 41, 42, 43, 44, 45, 46, 47, 48]
SYNC-PAD ::= 26                  // -> ESP32 IO27, the confirmed anchor wire.
SYNC-PULSES ::= 6
SYNC-HALF ::= Duration --ms=80   // 6.25 Hz burst, distinct from the 25 Hz slot wave.
LEAD-IN ::= Duration --ms=600    // Quiet gap after the sync burst, before slot 0.
SLOT ::= Duration --s=2
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
  sync := Ec618.pad SYNC-PAD
  sync.configure --output --value=0
  print "gpio-map-ec618: sync burst on PAD$SYNC-PAD ($SYNC-PULSES pulses)"
  drive-square sync SYNC-HALF (Duration --ms=(SYNC-PULSES * 2 * SYNC-HALF.in-ms))
  sync.close
  sleep LEAD-IN

  // Per-slot: drive each pad as a 25 Hz square wave for SLOT, in order.
  PADS.do: | pad/int |
    pin := Ec618.pad pad
    pin.configure --output --value=0
    print "gpio-map-ec618: slot driving PAD$pad"
    drive-square pin SLOT-HALF SLOT
    pin.close
  print "gpio-map-ec618: done"
