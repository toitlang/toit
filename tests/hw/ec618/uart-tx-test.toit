// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Level-3 EC618 unidirectional UART exerciser.
//
// Loops forever, stepping through every (UART, mapping, baud-rate)
// combination we can drive without flow-control pins or UART1 (which
// owns `print` in the default build).
//
// Pair with `tests/hw/ec618/uart-monitor.toit` running on an ESP32 wired
// up as follows (EC618 -> ESP32 GPIO):
//
//   GPIO15 (UART0 TX, "DBG-TX")  -> 26
//   GPIO11 (UART2 TX, primary pad PAD26) -> 32
//   GPIO11 (UART2 TX, alt pad   PAD22)   -> 35
//
// Run: `jag run -d air780e tests/hw/ec618/uart-tx-test.toit`
//
// The `print` stream goes out UART1 and announces the active phase, so
// you can correlate phase boundaries with whatever the ESP32 monitor
// reports on its RX pin.

import ec618 show Ec618
import uart

PHASE-MS ::= 5_000

main:
  cycle := 0
  while true:
    cycle++
    print "============================================="
    print "[cycle $cycle] start"
    print "============================================="

    // Phase 1: UART0 default at 115200 — should appear on ESP32 pin 26.
    transmit-uart0 --mapping=0 --baud=115200 --cycle=cycle
        --label="U0 default 115200"

    // Phase 2: UART0 default at 9600 — exercises baud reprogramming.
    transmit-uart0 --mapping=0 --baud=9600 --cycle=cycle
        --label="U0 default 9600"

    // Phase 3: UART0 alt mapping (TX=GPIO17 RX=GPIO16). The alt pad
    // isn't broken out, so the visible primary (GPIO15 -> ESP32 pin 26)
    // should go silent.
    transmit-uart0 --mapping=1 --baud=115200 --cycle=cycle
        --label="U0 alt 115200 (silence pin 26)"

    // Phase 4: UART2 default at 115200 — appears on whichever of ESP32
    // pins 32 / 35 is wired to the primary pad of GPIO11; the other
    // stays silent.
    transmit-uart2 --mapping=0 --baud=115200 --cycle=cycle
        --label="U2 default 115200"

    // Phase 5: UART2 default at 9600.
    transmit-uart2 --mapping=0 --baud=9600 --cycle=cycle
        --label="U2 default 9600"

    // Phase 6: UART2 alt 1 (TX=GPIO13 RX=GPIO12). Both broken-out pads
    // for UART2 default (32 and 35) should go silent.
    transmit-uart2 --mapping=1 --baud=115200 --cycle=cycle
        --label="U2 alt1 115200 (silence pins 32+35)"

    // Phase 7: full byte range on UART2 default.
    byte-range --cycle=cycle

    // Phase 8: UART0 and UART2 open at the same time.
    simultaneous --cycle=cycle

    print "[cycle $cycle] done"

transmit-uart0 --mapping/int --baud/int --cycle/int --label/string -> none:
  print "[cycle $cycle] phase: $label"
  port := Ec618.uart0 --mapping=mapping --baud-rate=baud
  try:
    deadline := Time.monotonic-us + PHASE-MS * 1_000
    n := 0
    while Time.monotonic-us < deadline:
      port.out.write "[$label c=$cycle n=$n]\n"
      n++
      sleep --ms=200
    print "  emitted $n lines"
  finally:
    port.close

transmit-uart2 --mapping/int --baud/int --cycle/int --label/string -> none:
  print "[cycle $cycle] phase: $label"
  port := Ec618.uart2 --mapping=mapping --baud-rate=baud
  try:
    deadline := Time.monotonic-us + PHASE-MS * 1_000
    n := 0
    while Time.monotonic-us < deadline:
      port.out.write "[$label c=$cycle n=$n]\n"
      n++
      sleep --ms=200
    print "  emitted $n lines"
  finally:
    port.close

byte-range --cycle/int -> none:
  print "[cycle $cycle] phase: U2 byte-range"
  port := Ec618.uart2 --baud-rate=115200
  try:
    port.out.write "[byte-range BEGIN c=$cycle]\n"
    payload := ByteArray 256: it
    port.out.write payload
    port.out.write "\n[byte-range END c=$cycle]\n"
    sleep --ms=500
  finally:
    port.close

simultaneous --cycle/int -> none:
  print "[cycle $cycle] phase: U0+U2 simultaneous"
  port0 := Ec618.uart0 --baud-rate=115200
  port2 := Ec618.uart2 --baud-rate=115200
  try:
    deadline := Time.monotonic-us + PHASE-MS * 1_000
    n := 0
    while Time.monotonic-us < deadline:
      port0.out.write "[U0 simul c=$cycle n=$n]\n"
      port2.out.write "[U2 simul c=$cycle n=$n]\n"
      n++
      sleep --ms=200
    print "  emitted $n lines on each port"
  finally:
    port0.close
    port2.close
