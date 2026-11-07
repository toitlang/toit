// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import expect show *
import uart
import system

// External UART0 echo. The onboard modem's GP0/GP1 are not selected as UART.
main:
  port := uart.Port --tx=16 --rx=17 --baud-rate=115_200
  try:
    with-timeout --ms=10_000:
      32.repeat: |round|
        data := ByteArray 256
        data.size.repeat: data[it] = (it + round) & 0xff
        port.out.write data
        system.process-stats --gc
        expect-equals data (port.in.read-bytes data.size)
  finally:
    port.close
  print "RP2040 UART echo/GC smoke: PASS"
