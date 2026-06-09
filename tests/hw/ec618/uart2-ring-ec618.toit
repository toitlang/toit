// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the UART2 driver RX-ring characterization test.

Locks in the (closed-source) PLAT UART driver's RX buffering behavior so an SDK
or config change that moves it gets noticed:
  - The RX ring holds exactly 32 KiB (32000 B survives a no-reader burst,
    33000 B does not).
  - On overflow the driver silently discards the ENTIRE buffered content (a
    burst one byte over capacity leaves zero readable bytes, not capacity-many),
    and the error callback does not fire ($uart.Port.errors stays 0).
  - WORSE: after one overflow, RX on the port is DEAD — later bursts that fit
    comfortably also deliver nothing — until the port is closed and reopened
    (Uart_BaseInitEx); set-baud (Uart_ChangeBR) does not recover it.
These were measured on 2026-06-10 (see docs/ec618-known-issues.md); if this test
fails after a third_party/SDK change, re-measure rather than assume a regression
in Toit code.

The ESP32 half is the uart2-bigdata-esp32.toit command server (B/S/Q over the
control lane); the EC618 sleeps through each burst so the ring has no reader.

Wiring: EC618 UART1 TX (PAD34) -> ESP32 IO4 (control);
        ESP32 IO14 -> EC618 UART2 RX (PAD25).

Run via the mini-jag tester (start uart2-bigdata-esp32.toit on the ESP32 first):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \\
      --chip ec618 --toit-exe build/host/sdk/bin/toit \\
      --port-board1 <ec618-uart0-port> tests/hw/ec618/uart2-ring-ec618.toit
*/

import ec618 show Ec618
import uart

CONTROL-BAUD ::= 115200
BAUD ::= 921600
RING ::= 32768

gen-byte i/int -> int: return (i * 31 + 7) & 0xff
PATTERN ::= ByteArray 4096 + 256: gen-byte it

main:
  control := Ec618.uart1 --baud-rate=CONTROL-BAUD --rx-disabled
  test := Ec618.uart2 --baud-rate=BAUD
  failures := []

  // [burst size, expected surviving bytes].
  [[4000, 4000], [32000, 32000], [33000, 0], [RING * 2, 0]].do: | probe/List |
    send := probe[0]
    expected := probe[1]
    control.out.write "B $BAUD\n"
    sleep --ms=500
    drain test

    control.out.write "S $send\n"
    wire-ms := send * 10 * 1000 / BAUD
    sleep --ms=wire-ms + 600          // No reader while the burst arrives.

    count := 0
    first-bad := -1
    while count < send:
      chunk/ByteArray? := null
      catch: chunk = with-timeout --ms=400: test.in.read
      if chunk == null: break
      if first-bad < 0:
        phase := count & 0xff
        if phase + chunk.size <= PATTERN.size:
          if chunk != PATTERN[phase .. phase + chunk.size]:
            chunk.size.repeat:
              if first-bad < 0 and chunk[it] != (gen-byte count + it):
                first-bad = count + it
      count += chunk.size
    ok := count == expected and first-bad == -1 and test.errors == 0
    print "uart2-ring-ec618: burst=$send survived=$count (want $expected) first-bad=$first-bad errors=$test.errors $(ok ? "ok" : "FAIL")"
    if not ok: failures.add "burst=$send"
    sleep --ms=300

  // The bursts above ended in an overflow, so the ring is now in its wedged
  // state: even a small burst must deliver NOTHING until the port is reopened.
  control.out.write "S 8192\n"
  sleep --ms=600
  wedged := 0
  while true:
    chunk/ByteArray? := null
    catch: chunk = with-timeout --ms=400: test.in.read
    if chunk == null: break
    wedged += chunk.size
  print "uart2-ring-ec618: post-overflow burst=8192 survived=$wedged (want 0: RX wedged until reopen)"
  if wedged != 0: failures.add "post-overflow"

  test.close
  test = Ec618.uart2 --baud-rate=BAUD
  control.out.write "S 8192\n"
  sleep --ms=600
  recovered := 0
  while true:
    chunk/ByteArray? := null
    catch: chunk = with-timeout --ms=400: test.in.read
    if chunk == null: break
    recovered += chunk.size
  print "uart2-ring-ec618: after-reopen burst=8192 survived=$recovered (want 8192)"
  if recovered != 8192: failures.add "reopen-recovery"

  control.out.write "Q\n"
  control.close
  test.close

  if not failures.is-empty:
    print "uart2-ring-ec618: FAIL $failures"
    throw "UART2 ring behavior changed: $failures"
  print "uart2-ring-ec618: PASS ring=32KiB, overflow discards all + wedges RX until reopen, errors counter silent"

drain port/uart.Port -> none:
  while true:
    data/ByteArray? := null
    catch: data = with-timeout --ms=150: port.in.read
    if data == null: return
