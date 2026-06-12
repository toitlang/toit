// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the UART1 round-trip test (device under test).

UART1 runs on the same CMSIS driver path as UART0/UART2 since the
uniform-uart migration; this locks in TX+RX round-trips on controller 1
at several bauds, in both reopen and set-baud modes (mirroring
uart2-echo-ec618, scaled down — UART1 is exercised as the one-way control
lane by every other test already).

Wiring: EC618 UART1 TX (PAD34) -> ESP32 IO4; ESP32 IO16 -> EC618 UART1 RX (PAD33).

Run via the mini-jag tester (start uart1-echo-esp32.toit on the ESP32 first):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \\
      --chip ec618 --toit-exe build/host/sdk/bin/toit \\
      --port-board1 <ec618-uart0-port> tests/hw/ec618/uart1-echo-ec618.toit
*/

import ec618 show Ec618
import uart

// 2 MBd is wiring-marginal on the test rig (long jumpers on the PAD33/
// IO16 net; it passed some days, failed others) — cap at the control
// lane's operational ceiling.
BAUDS ::= [115200, 460800, 921600]
PAYLOAD ::= 1024
MARKER0 ::= 0xF5
MARKER1 ::= 0x5F

gen-byte i/int -> int: return (i * 31 + 7) & 0xff

// Tells the helper (at the current baud) to hop to new-baud (0 = quit).
switch-helper port/uart.Port new-baud/int -> none:
  msg := ByteArray 6
  msg[0] = MARKER0
  msg[1] = MARKER1
  msg[2] = new-baud & 0xff
  msg[3] = (new-baud >> 8) & 0xff
  msg[4] = (new-baud >> 16) & 0xff
  msg[5] = (new-baud >> 24) & 0xff
  port.out.write msg
  port.out.flush
  // Generous settle: the helper tears down and reopens its port around
  // the hop, and at 2 MBd on jumper wiring the margins are thin.
  sleep --ms=600

round-trip port/uart.Port -> bool:
  pattern := ByteArray PAYLOAD: gen-byte it
  port.out.write pattern
  got := #[]
  e := catch:
    with-timeout --ms=3_000:
      while got.size < PAYLOAD:
        data := port.in.read
        if not data: break
        got += data
  return e == null and got == pattern

main:
  failures := []

  // Mode 1: reopen per baud.
  port/uart.Port? := null
  BAUDS.do: | baud/int |
    if port:
      switch-helper port baud
      port.close
    port = Ec618.uart1 --baud-rate=baud
    if not port: throw "open failed"
    sleep --ms=600
    ok := round-trip port
    print "uart1-echo-ec618: baud=$baud [reopen] round-trip $(ok ? "ok" : "FAIL")"
    if not ok: failures.add "$baud/reopen"

  // Mode 2: set-baud per baud (same port).
  BAUDS.do: | baud/int |
    switch-helper port baud
    port.baud-rate = baud
    sleep --ms=600
    ok := round-trip port
    print "uart1-echo-ec618: baud=$baud [set-baud] round-trip $(ok ? "ok" : "FAIL")"
    if not ok: failures.add "$baud/set-baud"

  switch-helper port 0   // Quit the helper.
  port.close

  if not failures.is-empty:
    print "uart1-echo-ec618: FAIL $failures"
    throw "UART1 round-trip failed: $failures"
  print "uart1-echo-ec618: PASS UART1 TX+RX round-trip clean at $BAUDS, both reopen and set-baud"
