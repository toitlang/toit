// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the UART2 RS485-half-duplex test.

Acts as the bus peer: receives each message on the test UART, verifies its
content, and echoes it back — while a background task counts rising edges
on the EC618's DE (direction) line at IO16. Per message it checks that

- exactly ONE DE pulse covered the message (a mid-message drop — e.g. the
  driver releasing the line between internal TX chunks — would show up as
  extra rises, and on a real bus as garbage);
- DE has dropped by shortly after the last byte;
- DE is low while THIS side transmits (the EC618 must be listening).

The plan (bauds, sizes, counts) is fixed and mirrored in
uart2-rs485-ec618.toit; there is no control lane. The big message is
acknowledged with a single 'K' so the EC618 knows the DE checks are done
before switching baud.

Wiring: EC618 UART2 TX (PAD26) -> IO27 (test RX);
        IO14 (test TX) -> EC618 UART2 RX (PAD25);
        EC618 PAD33 (DE) -> IO16.

Run via Jaguar, FIRST (so it is listening before the EC618 starts):

  jag run tests/hw/ec618/uart2-rs485-esp32.toit --device <esp32>
*/

import gpio
import uart

DE ::= 16
TEST-RX ::= 27
TEST-TX ::= 14

BAUDS ::= [9600, 115200, 921600]
ITERATIONS ::= 5
TOKEN-SIZE ::= 256
BIG-SIZE ::= 4096

main:
  de := gpio.Pin DE --input --pull-down
  failures := []

  rises := 0
  task --background::
    while true:
      de.wait-for 1
      rises++
      de.wait-for 0

  print "uart2-rs485-esp32: ready (DE IO$DE level $de.get; test IO$TEST-RX in / IO$TEST-TX out)"

  first := true
  BAUDS.do: | baud/int |
    rx := gpio.Pin TEST-RX
    tx := gpio.Pin TEST-TX
    port := uart.Port --rx=rx --tx=tx --baud-rate=baud

    ITERATIONS.repeat: | i/int |
      expected := ByteArray TOKEN-SIZE: (it * 31 + 7 + i) & 0xff
      before := rises
      // The very first read waits for the mini-jag upload + start.
      got := read-exactly port TOKEN-SIZE (first ? 120_000 : 15_000)
      first = false
      dropped := wait-low de
      pulses := rises - before
      ok := got == expected and dropped and pulses == 1
      print "uart2-rs485-esp32: $baud iter $i $(ok ? "ok" : "FAIL") (got $got.size, pulses $pulses, de-drop $dropped)"
      if not ok: failures.add "$baud/iter$i"
      if de.get != 0:
        print "uart2-rs485-esp32: $baud iter $i FAIL DE high while we transmit"
        failures.add "$baud/iter$(i)-de-busy"
      port.out.write got

    expected := ByteArray BIG-SIZE: (it * 31 + 7) & 0xff
    before := rises
    got := read-exactly port BIG-SIZE 15_000
    dropped := wait-low de
    pulses := rises - before
    ok := got == expected and dropped and pulses == 1
    print "uart2-rs485-esp32: $baud big $(ok ? "ok" : "FAIL") (got $got.size, pulses $pulses, de-drop $dropped)"
    if not ok: failures.add "$baud/big"
    port.out.write #['K']

    // Let the 'K' leave the wire before tearing the port down.
    sleep --ms=200
    port.close
    rx.close
    tx.close

  if failures.is-empty:
    print "uart2-rs485-esp32: PASS"
  else:
    print "uart2-rs485-esp32: FAIL $failures"

// Waits up to 1s for DE to drop (polling: the monitor task owns wait-for).
wait-low de/gpio.Pin -> bool:
  100.repeat:
    if de.get == 0: return true
    sleep --ms=10
  return false

// Reads exactly n bytes, allowing stall-ms between chunks.
read-exactly port/uart.Port n/int stall-ms/int -> ByteArray:
  result := #[]
  while result.size < n:
    chunk/ByteArray? := null
    catch: chunk = with-timeout --ms=stall-ms: port.in.read
    if chunk == null: break
    result += chunk
  return result.size > n ? result[..n] : result
