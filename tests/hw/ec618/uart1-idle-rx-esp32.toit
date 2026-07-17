// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the UART1 idle-RX test: sends a small marker into the
EC618's UART1 RX every 5 s for ~200 s (outlasting the EC618 half's
5 x 30 s window), then reports. No reading, no line parsing — the EC618
boot banner on our RX is ignored by construction.

Wiring: ESP32 IO16 -> EC618 PAD33 (UART1 RX); ESP32 IO4 <- EC618 PAD34.
*/

import gpio
import uart

MARKS ::= 40
INTERVAL-MS ::= 5_000

main:
  port := uart.Port --tx=(gpio.Pin 16) --rx=(gpio.Pin 4) --baud-rate=115200
  print "uart1-idle-rx-esp32: sending $MARKS marks, one per $(INTERVAL-MS)ms"
  MARKS.repeat: | i/int |
    port.out.write "MARK-$(%03d i)\n"
    sleep --ms=INTERVAL-MS
  port.close
  print "uart1-idle-rx-esp32: done"
