// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Host-side companion for `tests/hw/ec618/uart.toit`.
//
// Connect a USB<->UART adapter to the EC618 pins that correspond to the
// preset you are testing (TX<->RX, RX<->TX, common GND), then run this
// program with the adapter's device path as the first argument.
//
// Usage:
//
//   toit tests/hw/ec618/uart-desktop.toit /dev/ttyUSB0
//   toit tests/hw/ec618/uart-desktop.toit /dev/ttyUSB0 9600
//
// The program sends a fixed test payload, reads back the EC618's echo
// (bytes with bit 7 flipped) and checks that the number of echoed bytes
// matches what the device reports in its trailing "bytes-received=" line.

import expect show *
import io
import uart

PAYLOAD-SIZE ::= 256
READ-TIMEOUT-MS ::= 10_000

main args:
  if args.size < 1:
    print "Usage: uart-desktop.toit <device> [baud-rate]"
    print "  e.g.: uart-desktop.toit /dev/ttyUSB0 115200"
    exit 1

  device := args[0]
  baud-rate := args.size >= 2 ? int.parse args[1] : 115200

  print "Opening $device at $baud-rate baud"
  port := uart.Port device --baud-rate=baud-rate
  reader := port.in
  writer := port.out

  try:
    // Wait for the greeting line from the EC618 side.
    greeting := read-line reader
    print "device: $greeting"
    expect (greeting.starts-with "EC618 UART test:")

    // Send a fixed payload. Use a recognizable ramp so we notice off-by-one
    // framing errors immediately.
    payload := ByteArray PAYLOAD-SIZE: it & 0x7f
    writer.write payload
    writer.flush
    print "sent $payload.size bytes"

    // The device echoes each byte with bit 7 flipped.
    expected := ByteArray payload.size: payload[it] ^ 0x80
    received := read-exact reader expected.size
    expect-equals expected received
    print "echo matches"

    // The device prints a final summary when the test window closes.
    summary := read-line reader
    print "device: $summary"
    expect (summary.starts-with "bytes-received=")
    count := int.parse summary["bytes-received=".size ..]
    expect-equals payload.size count
    print "ALL TESTS PASSED"
  finally:
    port.close

read-line reader/io.Reader -> string:
  bytes := #[]
  while true:
    b := reader.read-byte
    if b == '\n': return bytes.to-string.trim
    bytes += #[b]

read-exact reader/io.Reader n/int -> ByteArray:
  out := ByteArray n
  offset := 0
  while offset < n:
    chunk := reader.read
    if chunk == null: throw "UART_CLOSED"
    take := min chunk.size (n - offset)
    out.replace offset chunk 0 take
    offset += take
    if take < chunk.size:
      // Shouldn't happen for the fixed payload, but guard just in case.
      throw "UNEXPECTED_EXTRA_DATA"
  return out
