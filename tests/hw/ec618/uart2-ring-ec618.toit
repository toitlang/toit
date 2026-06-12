// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the UART2 RX-ring contract test (CMSIS driver).

Locks in the Toit-owned RX ring behavior of the CMSIS UART2 path
(docs/ec618-uart-cmsis-rewrite.md, known-issues #7/#8) so a regression gets
noticed:
  - At >= 460800 baud the port defaults to --large-buffers: the ring holds
    32 KiB (one slot reserved, so 32767 usable; the armed 512-byte chunk and
    the 32-deep hardware FIFO add a little slack at the boundary).
  - On overflow the ring drops the NEWEST bytes: the SURVIVING bytes are an
    exact prefix of the sent stream (CRC-verified), and every dropped byte
    is counted in $uart.Port.errors.
  - RX SURVIVES an overflow: the next burst (with a reader) delivers fully.
    (The old blob driver discarded the whole buffer, kept errors at 0, and
    wedged RX until reopen — known-issues #4.)
  - set-baud does not disturb RX (it is a full controller power-cycle).

The ESP32 half is the uart2-bigdata-esp32.toit command server (B/S/Q over the
control lane); the EC618 sleeps through each burst so the ring has no reader.

Wiring: EC618 UART1 TX (PAD34) -> ESP32 IO4 (control);
        ESP32 IO14 -> EC618 UART2 RX (PAD25).

Run via the mini-jag tester (start uart2-bigdata-esp32.toit on the ESP32 first):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \\
      --chip ec618 --toit-exe build/host/sdk/bin/toit \\
      --port-board1 <ec618-uart0-port> tests/hw/ec618/uart2-ring-ec618.toit
*/

import crypto.crc show Crc32
import ec618 show Ec618
import uart

CONTROL-BAUD ::= 115200
BAUD ::= 921600
RING ::= 32768          // --large-buffers ring (default at this baud).
SLACK ::= 512 + 32      // Armed chunk + hardware FIFO can add up to this.

gen-byte i/int -> int: return (i * 31 + 7) & 0xff

// CRC-32 of the deterministic stream's first n bytes.
crc-of-stream n/int -> int:
  crc := Crc32
  chunk := ByteArray 4096
  off := 0
  while off < n:
    size := min chunk.size (n - off)
    size.repeat: chunk[it] = gen-byte (off + it)
    crc.add chunk 0 size
    off += size
  return crc.get-as-int

// Drains the port, returning [bytes-read, crc-32 of them].
drain-counted port/uart.Port -> List:
  crc := Crc32
  count := 0
  while true:
    chunk/ByteArray? := null
    catch: chunk = with-timeout --ms=400: port.in.read
    if chunk == null: return [count, crc.get-as-int]
    crc.add chunk
    count += chunk.size

drain port/uart.Port -> none:
  drain-counted port

main:
  control := Ec618.uart1 --baud-rate=CONTROL-BAUD --rx-disabled
  test := Ec618.uart2 --baud-rate=BAUD
  failures := []

  // A no-reader burst: [send size, min survivors, max survivors].
  // Fitting bursts survive completely; an over-capacity burst keeps an
  // exact PREFIX of ring-capacity-ish bytes and counts the dropped rest.
  probe := : | send/int lo/int hi/int label/string |
    control.out.write "B $BAUD\n"
    sleep --ms=500
    drain test
    errors-before := test.errors

    control.out.write "S $send\n"
    wire-ms := send * 10 * 1000 / BAUD
    sleep --ms=wire-ms + 600          // No reader while the burst arrives.

    result := drain-counted test
    count := result[0]
    crc-ok := result[1] == (crc-of-stream count)
    errs := test.errors - errors-before
    counted := count + errs
    ok := lo <= count and count <= hi
        and crc-ok
        and (send <= hi ? errs == 0 : errs > 0)
        and counted <= send and counted >= send - 100
    print "uart2-ring-ec618: $label burst=$send survived=$count (want $lo..$hi) prefix-crc=$(crc-ok ? "ok" : "BAD") errors=$errs accounted=$counted/$send $(ok ? "ok" : "FAIL")"
    if not ok: failures.add label
    sleep --ms=300

  probe.call 4000        4000        4000               "small"
  probe.call 32000       32000       32000              "near-capacity"
  probe.call 40000       (RING - 1)  (RING - 1 + SLACK) "overflow"
  // THE contract change vs the blob: RX must survive the overflow above.
  probe.call 4000        4000        4000               "post-overflow"

  // set-baud must not disturb RX either (full controller power-cycle).
  test.baud-rate = BAUD
  probe.call 4000        4000        4000               "post-set-baud"

  // And a reopen behaves like a fresh port.
  test.close
  test = Ec618.uart2 --baud-rate=BAUD
  probe.call 4000        4000        4000               "post-reopen"

  control.out.write "Q\n"
  control.close
  test.close

  if not failures.is-empty:
    print "uart2-ring-ec618: FAIL $failures"
    throw "UART2 ring contract broken: $failures"
  print "uart2-ring-ec618: PASS ring=32KiB(large-buffers), drop-newest counted in errors, exact prefix survives, RX survives overflow + set-baud + reopen"
