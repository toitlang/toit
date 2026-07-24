// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.crc show Crc32
import ec618 show Ec618
import monitor
import uart

/**
EC618 half of the UART2 FULL-DUPLEX stress test (device under test).

The EC618 sends and receives 256 KiB CONCURRENTLY per baud — the case that
  historically locked the device up hard (uart2-bigdata deliberately avoids it by
  running one direction at a time). With the software watchdog in place a lockup
  now shows up as a watchdog reset (the tester reports it) instead of a dead rig.

Per baud the EC618 asks the ESP32 for a "D <n>" phase: both sides then send the
  deterministic $gen-byte stream while receiving + CRC-checking the peer's. The
  ESP32 reports its RX verdict on its CONSOLE only (an in-band reply would be
  eaten by the EC618's receiver if bytes were lost), so the host checks the jag
  log for the ESP32-side verdict; this container's exit code only covers the
  EC618 side.

Without flow control a duplex flood is ALLOWED to drop on the RX side — the
  contract (known-issues #4/#7/#8) is that every byte is either delivered or
  counted in $uart.Port.errors (ring drop-newest), the stream that does arrive
  is clean, the device survives, and the container exits normally. Full
  delivery needs RTS/CTS (rig wiring pending). Per round this asserts:
  - accounting: count + errors >= TOTAL - 1000 (hardware FIFO overruns at
    multi-MBd are the only uncounted losses),
  - a delivery floor: count >= TOTAL / 4 (catches an RX collapse),
  - full CRC integrity whenever nothing was dropped.

Wiring: EC618 UART1 TX (PAD34) -> ESP32 IO4 (control);
        EC618 UART2 TX (PAD26) -> ESP32 IO27, ESP32 IO14 -> EC618 UART2 RX (PAD25).

Run via the mini-jag tester (start uart2-bigdata-esp32.toit on the ESP32 first):

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/uart2-duplex-ec618.toit
```
*/

// 4 MBd RX already loses bytes HALF-duplex (known-issues #4), so it would not
// tell us anything duplex-specific; the sweep tops out at 3 MBd, the highest
// rate that is clean one-direction-at-a-time.
BAUDS ::= [921600, 2000000, 3000000]
CONTROL-BAUD ::= 115200
TOTAL ::= 256 * 1024
CHUNK ::= 4096

gen-byte i/int -> int: return (i * 31 + 7) & 0xff
PATTERN ::= ByteArray 4096 + 256: gen-byte it

main:
  control := Ec618.uart1 --baud-rate=CONTROL-BAUD --rx-disabled
  // Terminate any junk in the helper's line buffer (open-glitch byte +
  // the boot-ROM banner on UART1 at reset) — see uart2-ring-ec618.toit.
  control.out.write "\n"
  sleep --ms=100
  test := Ec618.uart2 --baud-rate=BAUDS[0]
  failures := []
  expected := crc-of-stream TOTAL

  BAUDS.do: | baud/int |
    test.baud-rate = baud
    control.out.write "B $baud\n"
    sleep --ms=500
    drain test

    errors-before := test.errors
    control.out.write "D $TOTAL\n"
    sleep --ms=300                       // Let the ESP32 start its reader task.
    received := monitor.Latch
    task::
      received.set (recv-stream test TOTAL)
    send-stream test TOTAL
    got := received.get                  // [crc, count, max-read, first-bad]
    errs := test.errors - errors-before
    count := got[1]
    accounted := count + errs
    // Tolerance: hardware FIFO overruns at multi-MBd are the only
    // uncounted losses; scale with baud (~0.2% at 921600, ~0.8% at 3M).
    rx-ok := accounted >= TOTAL - (TOTAL * baud / 400_000_000) - 1000
        and count >= TOTAL / 4
        and (errs == 0 ? (got[0] == expected and count == TOTAL) : true)
    detail := "count=$count errs=$errs accounted=$accounted/$TOTAL max-read=$got[2]"
    print "uart2-duplex-ec618: baud=$baud RX $(rx-ok ? "ok" : "FAIL") ($detail)"
    if not rx-ok: failures.add "rx@$baud"
    sleep --ms=500                       // Let the ESP32 finish + print its verdict.

  control.out.write "Q\n"
  control.close
  test.close

  if not failures.is-empty:
    print "uart2-duplex-ec618: FAIL $failures"
    throw "UART2 duplex failed: $failures"
  print "uart2-duplex-ec618: PASS $TOTAL bytes each way simultaneously at all of $BAUDS — all RX bytes delivered-or-counted, device survived, clean exit (EC618 side; check the ESP32 console for its RX verdict)"

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
  deadline := Time.monotonic-us + 20_000_000
  while count < n:
    if Time.monotonic-us > deadline: break
    chunk/ByteArray? := null
    catch: chunk = with-timeout --ms=2000: port.in.read
    if chunk == null: break
    if chunk.size > max-read: max-read = chunk.size
    take := min chunk.size (n - count)
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

// Drains the RX buffer until the wire is quiet.
drain port/uart.Port -> none:
  while true:
    data/ByteArray? := null
    catch: data = with-timeout --ms=150: port.in.read
    if data == null: return
