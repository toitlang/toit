// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618

/**
EC618 UART open/close stress (device under test, no ESP32 needed).

Opens and closes UART2 repeatedly at a fixed baud to check that re-opening a UART
  controller works (it surfaced as an INVALID_ARGUMENT on a later open during the
  baud sweep). Isolates "re-open" from "baud value": all opens use the same baud.

Run via the mini-jag tester:

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/uart-reopen-ec618.toit
```
*/

// 460800 first (direct open), then a sweep that revisits it: isolates whether
// opening AT 460800 fails vs whether the position/sequence matters.
SEQUENCE ::= [460800, 9600, 38400, 115200, 230400, 460800, 921600, 3000000]

main:
  print "uart-reopen-ec618: open+close UART2 at each of $SEQUENCE"
  failures := []
  SEQUENCE.size.repeat: | i/int |
    baud := SEQUENCE[i]
    error := catch:
      port := Ec618.uart2 --baud-rate=baud
      port.close
    if error:
      print "uart-reopen-ec618: open #$(i + 1) @ $baud  FAILED -> $error"
      failures.add baud
    else:
      print "uart-reopen-ec618: open #$(i + 1) @ $baud  ok"
  if not failures.is-empty:
    print "uart-reopen-ec618: FAIL open rejected at baud(s) $failures"
    throw "UART2 open failed at $failures"
  print "uart-reopen-ec618: PASS all opens clean"
