// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import pulse-counter
import uart

main:
  port := uart.Port --tx=4 --baud-rate=115_200
  try:
    [[100, 25], [400, 50], [8000, 75], [100, 0], [100, 100]].do: | settings/List |
      frequency/int := settings[0]
      percent/int := settings[1]
      port.out.write "$frequency $percent\n"
      port.out.flush
      sleep --ms=150
      counter := pulse-counter.Unit 34
      start := Time.monotonic-us
      sleep --ms=1000
      edges := counter.value
      elapsed := Time.monotonic-us - start
      counter.close
      measured := edges * 1_000_000.0 / elapsed
      if percent == 0 or percent == 100:
        expect-equals 0 edges
      else:
        expect ((measured - frequency).abs < frequency * 0.025 + 2)
      pin := gpio.Pin 34 --input
      high := 0
      total := 0
      deadline := Time.monotonic-us + 1_000_000
      try:
        while Time.monotonic-us < deadline:
          high += pin.get
          total++
          if total & 0x3ff == 0: yield
      finally:
        pin.close
      duty := high * 100.0 / total
      expect ((duty - percent).abs < 6)
      print "pwm-gpio-esp32: PASS $frequency Hz $percent% (measured $measured Hz $duty%)"
    port.out.write "DONE\n"
    port.out.flush
    print "pwm-gpio-esp32: PASS"
  finally:
    port.close
