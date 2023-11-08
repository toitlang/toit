// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the pin-holding capability. Including with deep sleep.

# Setup
You need two boards.
- Connect GND of board1 to GND of board2.
- Connect pin 22 of board1 to pin 23 of board2.
- Connect pin 23 of board1 to pin 22 of board2.

Run `pin-hold-board1.toit` on board1.
Once that one is running, run `pin-hold-board2.toit` on board2.

Board2 will do deep-sleeps. With Jaguar it's ok to just rerun the
test again, but it's usually more convenient (and faster) to install
the test as a container so it's started automatically. In that case
you might want to disable Jaguar, so it doesn't try to connect to
the WiFi unnecessarily:

`jag container install -D jag.disabled -D jag.timeout=30s hold-test pin-hold1-board2.toit`
*/

PIN-OUT ::= 22
PIN-IN ::= 23

PIN-FREE-AND-UNUSED ::= 16
