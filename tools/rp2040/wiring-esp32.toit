// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import gpio

// Observe every proposed rig connection, including the unused BOOT and weak
// stimulus pins. No outputs or pull resistors are enabled on the ESP32.
PINS ::= [4, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33, 34, 35]

main:
  pins := []
  try:
    PINS.do: pins.add (gpio.Pin it --input)
    print "WIRE-ESP READY inputs-only"
    2400.repeat:
      mask := 0
      pins.size.repeat: |i|
        if pins[i].get == 1: mask |= 1 << PINS[i]
      print "WIRE-ESP $mask"
      sleep --ms=50
  finally:
    pins.do: it.close
