// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import uart

// Existing rig: ESP32 GPIO19/27/18/23/25 correspond to Pico GP4/5/6/7/26.
main:
  pins := [19, 27, 18, 23, 25].map: gpio.Pin it --input
  port := uart.Port --tx=4 --rx=34 --baud-rate=115_200
  try:
    with-timeout --ms=30_000:
      // Each pad must follow the far-end bias independently of every other pad.
      3.repeat:
        expect-equals 0 (command port "-1")
        expect-equals 0 (levels pins)
        pins.size.repeat: | i/int |
          expect-equals (1 << i) (command port "$i")
          expect-equals (1 << i) (levels pins)
      command port "OFF"
      3.repeat:
        pins.do: | pin/gpio.Pin | pin.set-pull --down
        expect-equals 0 (command port "READ")
        pins.size.repeat: | i/int |
          pins.size.repeat: | j/int |
            pin/gpio.Pin := pins[j]
            if i == j: pin.set-pull --up
            else: pin.set-pull --down
          expect-equals (1 << i) (command port "READ")
          expect-equals (1 << i) (levels pins)
      port.out.write "DONE\n"
      port.out.flush
      print "peripheral-wiring-esp32: PASS bidirectional weak pulls, mapping and isolation"
  finally:
    port.close
    pins.do: it.close

command port/uart.Port value/string -> int:
  port.out.write "$value\n"
  port.out.flush
  return int.parse (port.in.read-string-up-to '\n')

levels pins/List -> int:
  mask := 0
  pins.size.repeat: | i/int |
    pin/gpio.Pin := pins[i]
    mask |= pin.get << i
  return mask
