// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the exhaustive UART2 round-trip test (device under test).

Sweeps a set of baud rates in TWO modes:
  - "reopen": open UART2 fresh at each baud (close + re-open).
  - "set-baud": open UART2 once and change the baud per phase via the setter.
Both must work at every baud. For each, it tells the ESP32 the baud over a
CONTROL lane (UART1 TX, PAD34 -> ESP32 IO4), sends a token on UART2 TX, and
verifies the ESP32 echoes it back on UART2 RX — exercising UART2 TX *and* RX. The
control lane is what makes the sweep automatic (the ESP32 can't be given the baud
as a Jaguar program argument). Both directions are 3.3 V, so the EC618 UART2 RX
can be driven directly; each UART wire is one-directional (UART2 TX always
EC618-driven, UART2 RX always ESP32-driven), so there is no bus contention.

Wiring: EC618 UART1 TX (PAD34) -> ESP32 IO4 (control);
        EC618 UART2 TX (PAD26) -> ESP32 IO27, ESP32 IO14 -> EC618 UART2 RX (PAD25).

Run via the mini-jag tester (start uart2-echo-esp32.toit on the ESP32 first):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/uart2-echo-ec618.toit
*/

import ec618 show Ec618
import uart

BAUDS ::= [9600, 38400, 115200, 230400, 460800, 921600]
CONTROL-BAUD ::= 115200
TOKEN ::= "EC618-UART2-RT-0123456789ABCDEF"

main:
  control := Ec618.uart1 --baud-rate=CONTROL-BAUD --rx-disabled
  failures := []

  // Mode "reopen": a fresh UART2 open per baud. Open BEFORE telling the ESP32, so
  // the EC618 RX pad is an input before the ESP32 starts driving it.
  print "uart2-echo-ec618: mode=reopen, sweep $BAUDS"
  BAUDS.do: | baud/int |
    test := Ec618.uart2 --baud-rate=baud
    control.out.write "$baud\n"
    sleep --ms=400
    flush-rx test
    if not (round-trip test baud "reopen"): failures.add "$baud/reopen"
    test.close
    sleep --ms=150

  // Mode "set-baud": one UART2 open, change the baud per phase.
  print "uart2-echo-ec618: mode=set-baud, sweep $BAUDS"
  test := Ec618.uart2 --baud-rate=BAUDS[0]
  BAUDS.do: | baud/int |
    test.baud-rate = baud
    control.out.write "$baud\n"
    sleep --ms=400
    flush-rx test
    if not (round-trip test baud "set-baud"): failures.add "$baud/set-baud"
    sleep --ms=150
  test.close

  control.out.write "0\n"                 // Tell the ESP32 the sweep is done.
  control.close

  if not failures.is-empty:
    print "uart2-echo-ec618: FAIL no clean round-trip at $failures"
    throw "UART2 round-trip failed at $failures"
  print "uart2-echo-ec618: PASS UART2 TX+RX round-trip clean at all bauds, both reopen and set-baud"

// Drains the RX buffer until the wire is quiet, so a round-trip starts clean.
flush-rx test/uart.Port -> none:
  while true:
    data/ByteArray? := null
    catch: data = with-timeout --ms=80: test.in.read
    if data == null: return

// Sends TOKEN and waits for the echo to come back, tolerating leading garbage and
// chunked reads. Returns whether the token round-tripped within the timeout.
round-trip test/uart.Port baud/int mode/string -> bool:
  test.out.write "$TOKEN\n"
  buffer := ""
  found := false
  catch:
    with-timeout --ms=2500:
      while not found:
        chunk := test.in.read
        if chunk == null: break
        buffer += chunk.to-string-non-throwing
        if buffer.contains TOKEN: found = true
  print "uart2-echo-ec618: baud=$baud [$mode]  round-trip $(found ? "ok" : "FAIL")"
  return found
