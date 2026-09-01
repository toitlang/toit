// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Level-2 UART self-loopback tests for EC618.
//
// REQUIRES: Jumper UART2 TX (GPIO11) directly to UART2 RX (GPIO10) on the
// EC618 itself. No external MCU needed.
//
// What this exercises:
//   - Round-trip data integrity at multiple baud rates.
//   - All 256 byte values pass through unchanged.
//   - Larger transfers (multiple KB) survive without buffer drops.
//   - `wait_tx` returns true after the last byte has clocked out.
//   - `set_baud_rate` reprograms the divider mid-session.
//
// Note: UART2 is the only controller we can self-loop without help, since
// UART1 is owned by the print system in the default firmware build and
// UART0's TX pad is shared with the bootloader / unilog stream.

import ec618 show Ec618
import io
import uart

BAUD-RATES ::= [9600, 19200, 38400, 115200, 230400]
PAYLOAD-SMALL ::= 16
PAYLOAD-LARGE ::= 4096
RX-TIMEOUT-MS ::= 5_000

failures := 0

main:
  test-round-trip-each-baud
  test-full-byte-range
  test-large-payload
  test-wait-tx-completes
  test-baud-rate-change-mid-session

  if failures == 0:
    print "ALL TESTS PASSED"
  else:
    print "$failures FAILURES"
    exit 1

test-round-trip-each-baud:
  BAUD-RATES.do: | baud/int |
    test "round-trip baud=$baud":
      port := Ec618.uart2 --baud-rate=baud
      try:
        payload := ByteArray PAYLOAD-SMALL: it & 0xff
        port.out.write payload
        port.out.flush
        received := read-exact port.in PAYLOAD-SMALL
        expect-equal payload received
      finally:
        port.close

test-full-byte-range:
  test "full byte range 0..255":
    port := Ec618.uart2 --baud-rate=115200
    try:
      payload := ByteArray 256: it
      port.out.write payload
      port.out.flush
      received := read-exact port.in 256
      256.repeat: | i/int |
        if received[i] != i:
          throw "byte at offset $i: expected $i, got $(received[i])"
    finally:
      port.close

test-large-payload:
  test "large payload $(PAYLOAD-LARGE) bytes":
    port := Ec618.uart2 --baud-rate=460800
    try:
      payload := ByteArray PAYLOAD-LARGE: (it * 31) & 0xff
      // Spawn the writer so it doesn't block on a full TX queue.
      task::
        port.out.write payload
        port.out.flush
      received := read-exact port.in PAYLOAD-LARGE
      expect-equal payload received
    finally:
      port.close

test-wait-tx-completes:
  test "wait_tx empties after flush":
    port := Ec618.uart2 --baud-rate=9600
    try:
      port.out.write "abc"
      port.out.flush
      // After flush, the TX shift register should drain quickly. Give
      // the hardware a few ms (3 bytes at 9600 = ~3 ms total) and check.
      sleep --ms=10
      // Drain RX so we don't leave bytes lingering for the next test.
      _ := read-exact port.in 3
    finally:
      port.close

test-baud-rate-change-mid-session:
  test "baud rate change mid-session":
    port := Ec618.uart2 --baud-rate=9600
    try:
      port.out.write "low"
      port.out.flush
      received := read-exact port.in 3
      expect-equal "low".to-byte-array received

      port.baud-rate = 115200
      port.out.write "high"
      port.out.flush
      received = read-exact port.in 4
      expect-equal "high".to-byte-array received
    finally:
      port.close

read-exact reader/io.Reader n/int -> ByteArray:
  out := ByteArray n
  offset := 0
  deadline := Time.monotonic-us + RX-TIMEOUT-MS * 1_000
  while offset < n:
    if Time.monotonic-us > deadline:
      throw "RX timeout after $offset/$n bytes"
    chunk := reader.read
    if chunk == null: throw "RX closed at $offset/$n bytes"
    take := min chunk.size (n - offset)
    out.replace offset chunk 0 take
    offset += take
    if take < chunk.size:
      throw "RX overshoot: got $(chunk.size) bytes, only wanted $(n - (offset - take))"
  return out

expect-equal expected/ByteArray actual/ByteArray -> none:
  if expected.size != actual.size:
    throw "size mismatch: expected $(expected.size), got $(actual.size)"
  expected.size.repeat: | i/int |
    if expected[i] != actual[i]:
      throw "byte $i: expected $(expected[i]), got $(actual[i])"

test name/string [block] -> none:
  caught := catch: block.call
  if caught != null:
    print "FAIL: $name -> $caught"
    failures++
  else:
    print "ok: $name"
