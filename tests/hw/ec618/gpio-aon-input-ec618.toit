// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the AON-pad GPIO-input HW test (device under test).

Closes the last input gap in the per-pin coverage matrix
(docs/ec618-hw-tests.md): the AON pads PAD44 (GPIO24, board pin 18) and
PAD47 (GPIO27, board pin 27) are output-confirmed but were never read as
inputs. The ESP32 (gpio-aon-input-esp32.toit) drives BOTH wires at
DIFFERENT frequencies — IO19 fast, IO2 slow — and the EC618 reads both.

Passes if each pin sees both levels and enough edges, AND the fast wire
counts clearly more edges than the slow one on the pin it is supposed to
reach — a swapped or cross-coupled pair inverts/equalizes the ratio and
fails.

Wiring: ESP32 IO19 -> EC618 board pin 18 (GPIO24 / PAD44),
        ESP32 IO2  -> EC618 board pin 27 (GPIO27 / PAD47).

Run via the mini-jag tester (start gpio-aon-input-esp32.toit on the ESP32
first):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/gpio-aon-input-ec618.toit
*/

import gpio
import ec618 show Ec618

GPIO-FAST ::= 24                // PAD44, board pin 18, driven by ESP32 IO19 (10 Hz).
GPIO-SLOW ::= 27                // PAD47, board pin 27, driven by ESP32 IO2 (4 Hz).
SAMPLE ::= Duration --ms=2
WINDOW ::= Duration --s=20      // Inputs are configured first; the ESP32 starts a
                                // few seconds into this window (no shared barrier).
MIN-EDGES-FAST ::= 100          // 10 Hz over the overlap gives 100s of edges.
MIN-EDGES-SLOW ::= 40           // 4 Hz proportionally fewer.

main:
  fast := Ec618.gpio GPIO-FAST  // Opening an AON pad powers the AON IO LDO.
  slow := Ec618.gpio GPIO-SLOW
  fast.configure --input
  slow.configure --input
  print "gpio-aon-input-ec618: reading GPIO$GPIO-FAST (fast) + GPIO$GPIO-SLOW (slow) for $(WINDOW.in-s)s"

  last-fast := fast.get
  last-slow := slow.get
  saw0-fast := last-fast == 0
  saw1-fast := last-fast == 1
  saw0-slow := last-slow == 0
  saw1-slow := last-slow == 1
  edges-fast := 0
  edges-slow := 0
  deadline := Time.monotonic-us + WINDOW.in-us
  while Time.monotonic-us < deadline:
    v := fast.get
    if v != last-fast:
      edges-fast++
      last-fast = v
    if v == 0: saw0-fast = true else: saw1-fast = true
    v = slow.get
    if v != last-slow:
      edges-slow++
      last-slow = v
    if v == 0: saw0-slow = true else: saw1-slow = true
    sleep SAMPLE
  fast.close
  slow.close

  print "gpio-aon-input-ec618: fast edges=$edges-fast saw0=$saw0-fast saw1=$saw1-fast"
  print "gpio-aon-input-ec618: slow edges=$edges-slow saw0=$saw0-slow saw1=$saw1-slow"

  failures := []
  if not (edges-fast >= MIN-EDGES-FAST and saw0-fast and saw1-fast):
    failures.add "fast-pin (GPIO$GPIO-FAST/PAD44 input dead or weak)"
  if not (edges-slow >= MIN-EDGES-SLOW and saw0-slow and saw1-slow):
    failures.add "slow-pin (GPIO$GPIO-SLOW/PAD47 input dead or weak)"
  // Wire identity: the fast wire must land on the fast pin. A swap inverts
  // the ratio; coupling equalizes it.
  if edges-fast * 2 <= edges-slow * 3:
    failures.add "wire-identity (fast/slow edge ratio too low: $edges-fast vs $edges-slow)"

  if failures.is-empty:
    print "gpio-aon-input-ec618: PASS AON pads 44/47 read the ESP32 drive on the right wires"
  else:
    print "gpio-aon-input-ec618: FAIL $failures"
    throw "AON GPIO input failed: $failures"
