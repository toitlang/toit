// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the UART2 big-data / throughput / leak test (device under test).

Pushes a large, deterministic stream through UART2 in EACH direction at high baud
and checks that the UART keeps up (no drops/corruption) and that the heap does not
leak. Unlike an echo, neither side ever has to read-and-write at once, so the test
exercises the UART itself instead of the partner's full-duplex limit: the receiver
only reads + checksums (a native CRC-32 over whole chunks, never byte-bound), and
the sender only writes a stream both sides generate identically.

Per baud, two phases:
  - TX: EC618 sends $TOTAL bytes of $gen-byte; the ESP32 CRC-32s what it received
    and reports "C <crc> <count>" back. EC618 checks crc+count -> EC618 TX keep-up.
  - RX: ESP32 sends $TOTAL bytes of $gen-byte; EC618 CRC-32s what it received and
    compares to the expected (same generator) -> EC618 RX keep-up.
The heap is sampled (after a full GC) before and after the whole sweep; a stable
allocated figure means no leak across all the I/O.

Control lane (EC618 UART1 TX, PAD34 -> ESP32 IO4) carries newline commands:
  "B <baud>"  (re)open the test UART at <baud>
  "R <n>"     receive <n> bytes, then report "C <crc> <count>"
  "S <n>"     send <n> deterministic bytes
  "Q"         quit

Wiring: EC618 UART1 TX (PAD34) -> ESP32 IO4 (control);
        EC618 UART2 TX (PAD26) -> ESP32 IO27, ESP32 IO14 -> EC618 UART2 RX (PAD25).

Run via the mini-jag tester (start uart2-bigdata-esp32.toit on the ESP32 first):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/uart2-bigdata-ec618.toit
*/

import crypto.crc show Crc32
import ec618 show Ec618
import system
import uart

// High bauds: this is the keep-up test. The middle rates map the cliff between
// "clean at 921600" and "drops bytes at 4M".
BAUDS ::= [921600, 1500000, 2000000, 3000000, 4000000]
CONTROL-BAUD ::= 115200
TOTAL ::= 256 * 1024                    // Bytes per direction per baud.
CHUNK ::= 4096
LEAK-LIMIT ::= 8192                     // Tolerated retained-heap growth (post-GC).

// Deterministic stream both sides generate identically. Varies every byte so a
// drop or duplicate shifts the CRC. Period 256 (31 is odd), which lets the
// receiver compare incoming chunks against a precomputed pattern slice with the
// native blob-equals instead of a per-byte interpreter loop.
gen-byte i/int -> int: return (i * 31 + 7) & 0xff

// Two-plus periods of the stream followed by a max-size read chunk, so that
// PATTERN[off & 0xff .. (off & 0xff) + chunk.size] == stream bytes at off.
PATTERN ::= ByteArray 4096 + 256: gen-byte it

main:
  control := Ec618.uart1 --baud-rate=CONTROL-BAUD --rx-disabled
  // Terminate any junk in the helper's line buffer (open-glitch byte +
  // the boot-ROM banner on UART1 at reset) — see uart2-ring-ec618.toit.
  control.out.write "\n"
  sleep --ms=100
  test := Ec618.uart2 --baud-rate=BAUDS[0]
  failures := []

  expected := crc-of-stream TOTAL        // CRC-32 of gen-byte 0..TOTAL.
  baseline := (system.process-stats --gc)[system.STATS-INDEX-ALLOCATED-MEMORY]

  BAUDS.do: | baud/int |
    test.baud-rate = baud
    control.out.write "B $baud\n"
    sleep --ms=500
    drain test

    // Phase TX: EC618 -> ESP32. The ESP32 checksums and reports back.
    control.out.write "R $TOTAL\n"
    sleep --ms=400                       // Let the ESP32 enter its read loop.
    send-stream test TOTAL
    report := read-line test
    parsed := parse-report report
    tx-ok := parsed != null and parsed[0] == expected and parsed[1] == TOTAL
    print "uart2-bigdata-ec618: baud=$baud TX $(tx-ok ? "ok" : "FAIL ($report, want crc=$expected count=$TOTAL)")"
    if not tx-ok: failures.add "tx@$baud"
    sleep --ms=200
    drain test

    // Phase RX: ESP32 -> EC618. EC618 checksums what it receives. The extra
    // diagnostics pin down WHERE bytes go missing: first-bad is the stream
    // offset of the first wrong byte, max-read is the largest single read (≈ how
    // full the driver's RX ring got: near the ring size means the reader fell
    // behind to the brink), errs is the driver error-callback count for the
    // phase (overrun/parity/break seen by the hardware).
    errors-before := test.errors
    control.out.write "S $TOTAL\n"
    got := recv-stream test TOTAL         // [crc, count, max-read, first-bad]
    errs := test.errors - errors-before
    rx-ok := got[0] == expected and got[1] == TOTAL
    detail := "max-read=$got[2] first-bad=$got[3] errs=$errs"
    print "uart2-bigdata-ec618: baud=$baud RX $(rx-ok ? "ok ($detail)" : "FAIL (crc=$got[0] count=$got[1], want crc=$expected count=$TOTAL; $detail)")"
    if not rx-ok: failures.add "rx@$baud"
    sleep --ms=200

  final := (system.process-stats --gc)[system.STATS-INDEX-ALLOCATED-MEMORY]
  leak := final - baseline
  moved := 2 * BAUDS.size * TOTAL
  print "uart2-bigdata-ec618: moved $moved bytes total; heap-allocated baseline=$baseline final=$final delta=$leak"
  if leak > LEAK-LIMIT: failures.add "leak($leak)"

  control.out.write "Q\n"
  control.close
  test.close

  if not failures.is-empty:
    print "uart2-bigdata-ec618: FAIL $failures"
    throw "UART2 big-data failed: $failures"
  print "uart2-bigdata-ec618: PASS $TOTAL bytes/direction clean at all of $BAUDS, no leak"

// CRC-32 of the deterministic stream gen-byte 0..n (the expected value).
crc-of-stream n/int -> int:
  crc := Crc32
  off := 0
  while off < n:
    size := min CHUNK (n - off)
    crc.add (ByteArray size: gen-byte (off + it)) 0 size
    off += size
  return crc.get-as-int

// Sends n bytes of the deterministic stream.
send-stream port/uart.Port n/int -> none:
  off := 0
  while off < n:
    size := min CHUNK (n - off)
    port.out.write (ByteArray size: gen-byte (off + it))
    off += size

// Reads exactly n bytes (or fewer on timeout), returning
// [crc-32, bytes-read, max-single-read, first-bad-offset (-1 = none)].
recv-stream port/uart.Port n/int -> List:
  crc := Crc32
  count := 0
  max-read := 0
  first-bad := -1
  deadline := Time.monotonic-us + 12_000_000
  while count < n:
    if Time.monotonic-us > deadline: break
    chunk/ByteArray? := null
    catch: chunk = with-timeout --ms=2000: port.in.read
    if chunk == null: break
    if chunk.size > max-read: max-read = chunk.size
    take := min chunk.size (n - count)
    // Until the first corruption, verify content in-line (native blob-equals
    // against the precomputed pattern — cheap). After a drop everything shifts,
    // so only the FIRST bad offset is meaningful.
    if first-bad < 0:
      phase := count & 0xff
      if phase + take <= PATTERN.size:
        if chunk[..take] != PATTERN[phase .. phase + take]:
          take.repeat:
            if first-bad < 0 and chunk[it] != (gen-byte count + it):
              first-bad = count + it
    crc.add chunk 0 take
    count += take
  return [crc.get-as-int, count, max-read, first-bad]

// Reads one newline-terminated line (the ESP32's "C <crc> <count>" report).
read-line port/uart.Port -> string:
  buffer := ""
  catch:
    with-timeout --ms=6000:
      while not buffer.contains "\n":
        chunk := port.in.read
        if chunk == null: break
        buffer += chunk.to-string-non-throwing
  return buffer.trim

// Parses "C <crc> <count>" into [crc, count], or null if malformed.
parse-report report/string -> List?:
  parts := report.split " "
  if parts.size < 3 or parts[0] != "C": return null
  crc/int? := null
  count/int? := null
  catch: crc = int.parse parts[1]
  catch: count = int.parse parts[2]
  if crc == null or count == null: return null
  return [crc, count]

// Drains the RX buffer until the wire is quiet.
drain port/uart.Port -> none:
  while true:
    data/ByteArray? := null
    catch: data = with-timeout --ms=150: port.in.read
    if data == null: return
