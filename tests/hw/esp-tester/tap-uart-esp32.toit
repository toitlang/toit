// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Wire tap (poor-man's logic analyzer) on a UART net, e.g. the
// host->EC618 uart0 RX wire (CH340 TX -> PAD29, parallel tap on ESP32
// IO18 — INPUT only, the CH340 drives the net). Counts + CRCs each
// quiet-gap-delimited burst at the configured baud and reports on the
// jag console: shows byte-exactly what the wire carries while the
// device-under-test claims it received something else (known-issues #9
// was pinned to the chip with this — the wire was byte-perfect).
//
// Verify the wiring first: send a known pattern from the host (e.g.
// 16 x 'P' pings -> n=16 crc=3f762b06) and check the tap reports it.

import crypto.crc show Crc32
import gpio
import uart

TAP ::= 18
BAUD ::= 921600

main:
  port := uart.Port --rx=(gpio.Pin TAP) --tx=null --baud-rate=BAUD
  print "tap-uart0rx: listening on IO$TAP @ $BAUD"
  burst := 0
  while true:
    // Wait for first data of a burst.
    data := port.in.read
    if not data: continue
    crc := Crc32
    count := 0
    crc.add data
    count += data.size
    // Accumulate until 300 ms of quiet.
    while true:
      chunk/ByteArray? := null
      catch: chunk = with-timeout --ms=300: port.in.read
      if not chunk: break
      crc.add chunk
      count += chunk.size
    print "tap-uart0rx: burst#$burst n=$count crc=$(%08x crc.get-as-int) errors=$port.errors"
    burst++
