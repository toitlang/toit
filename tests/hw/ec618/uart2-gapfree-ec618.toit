// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import uart

/**
EC618 half of the UART gap-free-TX test (device under test).

A normal UART is allowed to pause between bytes — but when the UART is
  (ab)used as a waveform generator for LED strips, ANY pause on the wire
  corrupts the protocol (an idle line reads as a long high / latch). This
  test asserts the TX path emits a multi-chunk burst with NO pause the
  detector can see, at every tested baud.

Method (see uart2-gapfree-esp32.toit for the detector math): the payload
  is all-0x00 bytes, so a gap-free stream never holds the wire high longer
  than one stop bit; the ESP32's glitch-filtered pulse counter then counts
  rising edges = pauses + 1 (trailing idle).
  Each baud runs two phases:

1. Positive control: the same payload written as two halves with a 20 ms
   sleep between them — the detector MUST count >= 2 (proves it is armed
   and sensitive before we trust any zero).
2. Gap-free: one 32 KiB write --flush (crossing many TX-DMA staging-chunk
   seams — the place a pause would live) — the count MUST be exactly 1.

The wall-clock of the flush is also checked against the wire time (a
  coarse, filter-independent bound, same idea as uart2-flush).

Wiring: EC618 UART2 TX (PAD26) -> IO27 (watched);
        EC618 UART1 (PAD34 -> IO4, IO16 -> PAD33) = command lane.

Run via the mini-jag tester (start uart2-gapfree-esp32.toit FIRST):

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/uart2-gapfree-ec618.toit
```
*/

// The SUPPORTED gap-free contract (Florian, 2026-07-16): any length up
// to 921600 (multi-chunk seams are IRQ-chained); at pixel-strip rates
// (2.5 MBd) a single write of at most one staging buffer. The WS2812B
// recipe: 9 UART signals (start bit + 7 data bits + stop bit, line
// INVERTED by an external NOT gate — the EC618 cannot invert TX) carry
// 3 protocol bits, so one 24-bit LED = 8 UART bytes and a 4 KiB frame
// = 512 LEDs (~61 fps) — enough for now. Multi-chunk at MBd rates has
// ~3 us splice seams — known-issues #13 documents the (unplanned)
// descriptor-chaining enhancement.
BAUDS ::= [115_200, 921_600, 2_500_000]
payload-size-for baud/int -> int:
  return baud >= 2_000_000 ? 4 * 1024 : 32 * 1024

failures := []

main:
  print "uart2-gapfree-ec618: starting"
  control := Ec618.uart1 --baud-rate=115200
  control.out.write "\n"     // Fresh-open glitch-byte flush (rig rule).
  print "uart2-gapfree-ec618: control lane open"

  BAUDS.do: | baud/int |
    size := payload-size-for baud
    payload := ByteArray size  // All zeros — exactly what we want.
    test := Ec618.uart2 --baud-rate=baud
    wire-ms := size * 10 * 1000 / baud
    window-ms := wire-ms + 2_000  // Arm latency + margin + trailing idle.
    // Filter: must exceed the stop-bit high (1 bit) and stay below the
    // 9-bit low runs of the 0x00 payload; ~3 bit times, capped at PCNT's
    // ~12.7us maximum. The detectable-pause floor is thus ~3 bit times.
    filter-ns := min 12_000 (3 * 1_000_000_000 / baud)
    print "uart2-gapfree-ec618: baud=$baud wire=$(wire-ms)ms window=$(window-ms)ms filter=$(filter-ns)ns"

    // Phase 1: positive control — a deliberate pause must be detected.
    count := measure control window-ms filter-ns:
      test.out.write payload[..size / 2] --flush
      sleep --ms=20
      test.out.write payload[size / 2..] --flush
    check "$baud: detector sees the deliberate pause" (count >= 2)
        --detail="count=$count (want >= 2)"

    // Phase 2: the real assertion — one burst, no pauses.
    elapsed-us/int? := null
    count = measure control window-ms filter-ns:
      start := Time.monotonic-us
      test.out.write payload --flush
      elapsed-us = Time.monotonic-us - start
    check "$baud: burst is gap-free" (count == 1)
        --detail="count=$count (want exactly 1 = trailing idle only)"
    // Coarse wall-clock cross-check: the flush cannot beat the wire time
    // (minus the ~1.2% crystal tolerance — the real bit clock runs a hair
    // fast on this module, measured by the pwm tests), and big
    // accumulated pauses would show up here even below the detector's
    // floor.
    wire-us := size * 10 * 1_000_000 / baud
    timing-ok := elapsed-us >= wire-us * 97 / 100 and elapsed-us < wire-us + wire-us / 10 + 50_000
    check "$baud: flush matches wire time" timing-ok
        --detail="$(elapsed-us)us for $(wire-us)us of wire"

    test.close

  control.out.write "Q\n"
  control.close

  if not failures.is-empty:
    print "uart2-gapfree-ec618: FAIL $failures"
    throw "UART gap-free TX failed: $failures"
  print "uart2-gapfree-ec618: PASS"

check label/string ok/bool --detail/string -> none:
  print "uart2-gapfree-ec618: $label $(ok ? "ok" : "FAIL") ($detail)"
  if not ok: failures.add label

// Arms the ESP32 detector for $window-ms, runs $work (the transmission),
// and returns the filtered rising-edge count.
measure control/uart.Port window-ms/int filter-ns/int [work] -> int:
  control.out.write "G $window-ms $filter-ns\n"
  sleep --ms=300  // Let the detector arm.
  print "uart2-gapfree-ec618: armed, transmitting"
  work.call
  print "uart2-gapfree-ec618: transmitted, awaiting count"
  reply := read-line control --timeout-ms=(window-ms + 3_000)
  parts := reply.split " "
  if parts.size != 2 or parts[0] != "G": throw "bad detector reply: '$reply'"
  return int.parse parts[1]

read-line control/uart.Port --timeout-ms/int -> string:
  buffer := #[]
  with-timeout --ms=timeout-ms:
    while true:
      nl := buffer.index-of '\n'
      if nl >= 0: return buffer[..nl].to-string.trim
      chunk := control.in.read
      if chunk == null: throw "control lane closed"
      buffer += chunk
  unreachable
