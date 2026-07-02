// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// ESP32-side controller for `tests/hw/ec618/uart-bidirectional-test.toit`.
//
// Sends test lines to the EC618 and verifies the uppercase echo. Args:
//
//   jag run -d esp32 tests/hw/ec618/uart-controller.toit -- 32 33 [baud]
//
// Where 32 is the ESP32 GPIO wired to EC618 GPIO11 (TX from EC618's
// perspective, RX on ESP32) and 33 is the ESP32 GPIO wired to EC618
// GPIO10 (RX from EC618, TX on ESP32). Default baud is 115200.

import gpio
import io
import uart

LINES ::= [
  "hello",
  "the quick brown fox",
  "0123456789",
  "lots of mixed case Stuff Here 12!",
]

RX-TIMEOUT-MS ::= 5_000

main args:
  if args.size < 2:
    print "Usage: uart-controller.toit <esp-rx-pin> <esp-tx-pin> [baud-rate]"
    return
  rx-num := int.parse args[0]
  tx-num := int.parse args[1]
  baud-rate := args.size >= 3 ? int.parse args[2] : 115200

  print "Controller: ESP32 RX=$rx-num TX=$tx-num baud=$baud-rate"
  rx := gpio.Pin rx-num
  tx := gpio.Pin tx-num
  port := uart.Port --tx=tx --rx=rx --baud-rate=baud-rate

  failures := 0
  try:
    LINES.do: | line/string |
      port.out.write "$line\n"
      port.out.flush
      reply := read-line port.in
      expected := line.to-ascii-upper
      if reply == expected:
        print "ok: $line -> $reply"
      else:
        print "FAIL: $line -> $reply (expected $expected)"
        failures++

    if failures == 0:
      print "ALL TESTS PASSED"
    else:
      print "$failures FAILURES"
      exit 1
  finally:
    port.close
    rx.close
    tx.close

read-line reader/io.Reader -> string:
  bytes := #[]
  deadline := Time.monotonic-us + RX-TIMEOUT-MS * 1_000
  while true:
    if Time.monotonic-us > deadline: throw "RX timeout"
    b := reader.read-byte
    if b == '\n': return bytes.to-string.trim
    bytes += #[b]
