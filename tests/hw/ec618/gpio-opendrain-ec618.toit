// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the GPIO open-drain test (device under test).

The EC618 has no native open-drain; the driver emulates it by making the
pin direction track the value (output-low for 0, high-Z for 1). This test
puts that emulation on a real two-master bus: EC618 PAD33 and ESP32 IO16
share the wire, both open-drain, pull-ups on both sides. Checks:

- driving 0 pulls the wire low; releasing lets the pull-up raise it;
- `get` reads the WIRE, not the latch: with the EC618 released and the
  ESP32 pulling low, the EC618 reads 0 (the wired-AND property);
- repeated set 0/1 toggling;
- `set-open-drain` flips between emulated open-drain and push-pull live;
- open-drain WITHOUT the internal pull-up (external pull-up only — the
  classic configuration), including a high-Z proof: a released pin loses
  against the peer's weak pull-down, which a push-pull high would win.

The ESP32 measures/acts on command over UART2; all assertions run here.

Wiring: EC618 UART2 (PAD26 -> IO27, IO14 -> PAD25) = command lane;
        EC618 PAD33 <-> IO16 = the open-drain bus wire.

Run via the mini-jag tester (start gpio-opendrain-esp32.toit FIRST):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/gpio-opendrain-ec618.toit
*/

import ec618 show Ec618
import gpio
import uart

failures := []

main:
  control := Ec618.uart2 --baud-rate=115200

  // Bus idle, EC618 side unopened: the ESP32 pull-up must win.
  reply := exchange control "B"
  check (reply[1] == "1") "idle-high (got $reply[1])"

  // Open as open-drain; the constructor's default value 0 drives low.
  od := gpio.Pin 33 --input --output --open-drain --pull-up
  check ((remote-read control) == 0) "drive-0"
  check (od.get == 0) "drive-0-readback"

  // Release: both pull-ups raise the wire.
  od.set 1
  check ((remote-read control) == 1) "release-1"
  check (od.get == 1) "release-1-readback"

  // Wired-AND: the ESP32 pulls low while we are released.
  exchange control "O 0"
  check (od.get == 0) "wired-and-peer-low"
  exchange control "O 1"
  check (od.get == 1) "wired-and-both-released"
  exchange control "C"

  // Toggle a few times.
  5.repeat: | i/int |
    od.set 0
    check ((remote-read control) == 0) "toggle-$(i)-low"
    od.set 1
    check ((remote-read control) == 1) "toggle-$(i)-high"

  // Live switch to push-pull and back.
  od.set-open-drain false
  check ((remote-read control) == 1) "pushpull-high"
  od.set-open-drain true
  check ((remote-read control) == 1) "od-again-high"
  od.set 0
  check ((remote-read control) == 0) "od-again-low"

  od.set 1
  od.close
  check ((remote-read control) == 1) "closed-released"

  // Phase 2: open-drain WITHOUT the internal pull-up — the classic
  // configuration where an external pull-up (here: the ESP32's) supplies
  // the high level.
  od = gpio.Pin 33 --output --open-drain
  check ((remote-read control) == 0) "nopull-drive-0"
  od.set 1
  check ((remote-read control) == 1) "nopull-release"
  check (od.get == 1) "nopull-release-readback"
  // High-Z proof: against a weak pull-DOWN on the peer, a released pin
  // reads 0 — a push-pull pin driving 1 would win over the pull.
  exchange control "P d"
  check (od.get == 0) "nopull-release-highz"
  od.set 0
  check (od.get == 0) "nopull-drive-0-pulldown"
  exchange control "P u"
  od.set 1
  od.close

  control.out.write "Q\n"
  control.close

  if not failures.is-empty:
    print "gpio-opendrain-ec618: FAIL $failures"
    throw "GPIO open-drain test failed: $failures"
  print "gpio-opendrain-ec618: PASS"

check ok/bool label/string -> none:
  print "gpio-opendrain-ec618: $label $(ok ? "ok" : "FAIL")"
  if not ok: failures.add label

remote-read control/uart.Port -> int:
  reply := exchange control "R"
  return int.parse reply[1]

// Sends a command and reads one newline-terminated reply.
exchange control/uart.Port command/string -> List:
  control.out.write "$command\n"
  buffer := #[]
  with-timeout --ms=10_000:
    while true:
      nl := buffer.index-of '\n'
      if nl >= 0: return (buffer[..nl].to-string.trim.split " ")
      chunk := control.in.read
      if chunk == null: throw "control lane closed"
      buffer += chunk
  unreachable
