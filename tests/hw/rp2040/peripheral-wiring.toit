// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import uart

// Check the existing rig connections as inputs. GP16/17 carry the UART.
main:
  pins := [4, 5, 6, 7, 26].map: gpio.Pin it --input
  port := uart.Port --tx=16 --rx=17 --baud-rate=115_200
  try:
    print "peripheral-wiring-rp2040: READY"
    while true:
      line := (port.in.read-string-up-to '\n')
      if line == "DONE": break
      if line == "OFF":
        pins.do: | pin/gpio.Pin | pin.set-pull --off
      else if line != "READ":
        selected := int.parse line
        expect (-1 <= selected < pins.size)
        pins.size.repeat: | i/int |
          pin/gpio.Pin := pins[i]
          if i == selected: pin.set-pull --up
          else: pin.set-pull --down
      sleep --ms=5
      mask := 0
      pins.size.repeat: | i/int |
        pin/gpio.Pin := pins[i]
        mask |= pin.get << i
      port.out.write "$mask\n"
      port.out.flush
    print "peripheral-wiring-rp2040: PASS"
  finally:
    port.close
    pins.do: it.close
