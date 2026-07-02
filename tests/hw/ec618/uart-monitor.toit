// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// ESP32-side companion for `tests/hw/ec618/uart-tx-test.toit`.
//
// Opens a single UART in RX-only mode and dumps everything that arrives,
// line by line when possible (so the EC618's `\n`-terminated phase markers
// land as one print), or as hex for chunks without a newline.
//
// Pin guide for the test rig (EC618 -> ESP32 GPIO):
//
//   GPIO15 (DBG-TX, UART0)        -> 26
//   GPIO19 (TX1)                  -> 12   (only useful when UART1 is freed)
//   GPIO11 (TX2 primary pad)      -> 32
//   GPIO11 (TX2 alt pad)          -> 35
//
// Run, picking the ESP32 RX pin to listen on:
//
//   jag run -d esp32 tests/hw/ec618/uart-monitor.toit -- 26
//   jag run -d esp32 tests/hw/ec618/uart-monitor.toit -- 32 9600
//
// A keepalive print every $ALIVE-MS makes silent phases visible.

import gpio
import monitor
import uart

ALIVE-MS ::= 1_000
MAX-LINE ::= 1024

main args:
  if args.size < 1:
    print "Usage: uart-monitor.toit <rx-pin> [baud-rate]"
    print "  rx-pin: ESP32 GPIO wired to the EC618 TX line"
    print "  baud-rate: must match the EC618 phase you want to capture (default 115200)"
    return

  rx-num := int.parse args[0]
  baud-rate := args.size >= 2 ? int.parse args[1] : 115200

  print "Listening on RX=$rx-num at $baud-rate baud (Ctrl-C to stop)"
  rx := gpio.Pin rx-num
  port := uart.Port --tx=null --rx=rx --baud-rate=baud-rate

  total-bytes := 0
  last-rx-us := Time.monotonic-us
  buffer := #[]

  // Keepalive task so silent phases don't look like a hang.
  task::
    while true:
      sleep --ms=ALIVE-MS
      now := Time.monotonic-us
      idle-ms := (now - last-rx-us) / 1000
      print "  -- alive, total=$total-bytes bytes, idle=$(idle-ms)ms --"

  try:
    while true:
      chunk := port.in.read
      if chunk == null: break
      total-bytes += chunk.size
      last-rx-us = Time.monotonic-us
      buffer += chunk

      // Emit complete lines as soon as they're in the buffer.
      while true:
        nl := buffer.index-of '\n'
        if nl < 0: break
        line := buffer[..nl]
        buffer = buffer[nl + 1..]
        emit-line line

      // If the buffer grows too far without ever seeing a newline, dump it
      // as hex so we don't accumulate forever.
      if buffer.size > MAX-LINE:
        print "rx (hex, $buffer.size bytes, no newline): $(hex buffer)"
        buffer = #[]
  finally:
    port.close
    rx.close

emit-line bytes/ByteArray:
  // EC618 phase markers are pure ASCII. The byte-range phase emits the
  // full 0..255 sandwich; for that we drop into hex automatically.
  printable := true
  bytes.do: | b |
    if b < 0x20 or b > 0x7e:
      // Allow trailing CR (the EC618 program writes "\n", but cabling can
      // sometimes interpose CRs).
      if b != '\r': printable = false
  if printable:
    print "rx: $(bytes.to-string-non-throwing)"
  else:
    print "rx (hex, $bytes.size bytes): $(hex bytes)"

hex bytes/ByteArray -> string:
  parts := []
  bytes.do: parts.add "$(%02x it)"
  return parts.join " "
