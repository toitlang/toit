// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import uart

// Run only after the input-only wiring check: GP16 -> GPIO34, GP17 <- GPIO4.
main:
  port := uart.Port --tx=4 --rx=34 --baud-rate=115_200
  try:
    print "RP2040 UART PEER READY"
    while data := port.in.read:
      port.out.write data
  finally:
    port.close
