// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the UART1 round-trip test: echoes everything it receives.

The EC618's UART1 TX (PAD34) doubles as the control lane in the other
tests; here it is simply the test TX. The echo goes back over IO16 into
the EC618's UART1 RX (PAD33 — the same wire the watchdog scope-trigger
uses, which is only driven on a fatal).

Wiring: EC618 UART1 TX (PAD34) -> IO4 (rx); IO16 (tx) -> EC618 UART1 RX (PAD33).

The EC618 side opens at one baud per "round": it switches this port on
the magic PAIR 0xF5 0x5F followed by 4 little-endian baud bytes (sent at
the CURRENT baud before switching; 0 = quit). The test pattern has
consecutive deltas of +31, so the pair can never occur in payload.

Run via Jaguar, FIRST: jag run tests/hw/ec618/uart1-echo-esp32.toit --device <esp32>
*/

import gpio
import uart

RX ::= 4
TX ::= 16
MARKER0 ::= 0xF5
MARKER1 ::= 0x5F

// Index of the marker pair, or -1.
find-marker data/ByteArray -> int:
  (data.size - 1).repeat:
    if data[it] == MARKER0 and data[it + 1] == MARKER1: return it
  return -1

main:
  baud := 115200
  while true:
    rx := gpio.Pin RX
    tx := gpio.Pin TX
    port := uart.Port --rx=rx --tx=tx --baud-rate=baud
    print "uart1-echo-esp32: echoing at $baud (rx IO$RX / tx IO$TX)"
    pending := #[]
    new-baud/int? := null
    while true:
      data := port.in.read
      if not data: continue
      pending += data
      // Scan for the baud-switch marker pair; echo everything before it.
      idx := find-marker pending
      while idx >= 0 and pending.size < idx + 6:
        more := port.in.read
        if more: pending += more
      if idx >= 0:
        if idx > 0: port.out.write pending[..idx]
        b := pending[idx + 2 ..]
        new-baud = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)
        break
      // A trailing lone 0xF5 might be half a marker: hold it back.
      hold := pending[pending.size - 1] == MARKER0 ? 1 : 0
      if pending.size - hold > 0: port.out.write pending[.. pending.size - hold]
      pending = pending[pending.size - hold ..]
    port.out.flush
    port.close
    rx.close
    tx.close
    if new-baud == 0:
      print "uart1-echo-esp32: done"
      return
    baud = new-baud
