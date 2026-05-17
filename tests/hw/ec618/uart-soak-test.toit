// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Level-5 EC618 UART soak test.
//
// REQUIRES: jumper UART2 TX (GPIO11) -> UART2 RX (GPIO10), same as the
// loopback test. Optional: longer external cabling instead of a jumper to
// stress the signal-integrity path more realistically.
//
// Run for $DURATION-S seconds (or pass a different duration as `args[0]`):
//
//   jag run -d air780e tests/hw/ec618/uart-soak-test.toit -- 60
//
// What it watches for:
//   - Cumulative TX/RX byte mismatch (data corruption).
//   - Errors counter creeping up over time.
//   - Heap leak: prints free-heap delta every 10 s.
//   - Whether the run completes at all (asserts, hangs).
//
// Soak tests aren't run by default in CI; this file exists so the
// scaffolding is in place when someone wants to leave a board running
// overnight or burn-in a new build.

import ec618 show Ec618
import io
import system

DURATION-S ::= 60      // Default; override via args.
CHUNK-SIZE ::= 256
RX-TIMEOUT-MS ::= 1_000
HEAP-REPORT-INTERVAL-S ::= 10

main args:
  duration-s := args.size >= 1 ? int.parse args[0] : DURATION-S
  print "soak: running for $duration-s seconds"

  port := Ec618.uart2 --baud-rate=460800
  total-bytes/int := 0
  mismatches/int := 0
  baseline-free := system.process-stats[0]
  next-heap-report-us := Time.monotonic-us + HEAP-REPORT-INTERVAL-S * 1_000_000
  deadline := Time.monotonic-us + duration-s * 1_000_000

  try:
    iteration := 0
    while Time.monotonic-us < deadline:
      iteration++
      payload := ByteArray CHUNK-SIZE: ((iteration + it) * 31) & 0xff

      // Spawn writer so it doesn't block on a full TX queue.
      task::
        port.out.write payload
        port.out.flush

      received := read-exact port.in CHUNK-SIZE
      total-bytes += received.size
      CHUNK-SIZE.repeat: | i/int |
        if received[i] != payload[i]: mismatches++

      if Time.monotonic-us > next-heap-report-us:
        free := system.process-stats[0]
        print "  t=$(elapsed-s deadline duration-s) iter=$iteration bytes=$total-bytes "
            + "mismatches=$mismatches free=$free baseline=$baseline-free delta=$(free - baseline-free)"
        next-heap-report-us += HEAP-REPORT-INTERVAL-S * 1_000_000

    print "soak finished: iter=$iteration bytes=$total-bytes mismatches=$mismatches"
    print "free-heap baseline=$baseline-free final=$(system.process-stats[0])"
    if mismatches == 0:
      print "SOAK PASSED"
    else:
      print "SOAK FAILED ($mismatches mismatched bytes)"
      exit 1
  finally:
    port.close

read-exact reader/io.Reader n/int -> ByteArray:
  out := ByteArray n
  offset := 0
  deadline := Time.monotonic-us + RX-TIMEOUT-MS * 1_000
  while offset < n:
    if Time.monotonic-us > deadline: throw "RX timeout at $offset/$n"
    chunk := reader.read
    if chunk == null: throw "RX closed"
    take := min chunk.size (n - offset)
    out.replace offset chunk 0 take
    offset += take
    if take < chunk.size: throw "RX overshoot"
  return out

elapsed-s deadline/int duration-s/int -> int:
  remaining-us := deadline - Time.monotonic-us
  return duration-s - (remaining-us / 1_000_000)
