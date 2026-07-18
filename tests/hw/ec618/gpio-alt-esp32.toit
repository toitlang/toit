// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
ESP32 half of the alternate-pad GPIO output test.

EC618 PAD13 / GPIO14 ALT4 is wired to IO17, and PAD14 / GPIO15 ALT4 to IO18.
Count the two distinct square waves emitted by gpio-alt-ec618.toit.
*/

import gpio

WAIT ::= Duration --s=40
WINDOW ::= Duration --s=18
SAMPLE ::= Duration --ms=2

main:
  pins := [gpio.Pin 17 --input --pull-down, gpio.Pin 18 --input --pull-down]
  names := ["GPIO14/PAD13", "GPIO15/PAD14"]
  expected-min := [400, 250]
  expected-max := [1000, 700]

  print "gpio-alt-esp32: waiting for EC618 alternate-pad activity"
  idle := [pins[0].get, pins[1].get]
  caught := catch:
    with-timeout WAIT:
      while pins[0].get == idle[0] and pins[1].get == idle[1]: sleep SAMPLE
  if caught:
    print "gpio-alt-esp32: FAIL no activity"
    pins.do: | pin/gpio.Pin | pin.close
    return

  edges := [0, 0]
  last := [pins[0].get, pins[1].get]
  deadline := Time.monotonic-us + WINDOW.in-us
  while Time.monotonic-us < deadline:
    2.repeat: | i/int |
      value := pins[i].get
      if value != last[i]:
        edges[i]++
        last[i] = value
    sleep SAMPLE

  failed := false
  2.repeat: | i/int |
    print "gpio-alt-esp32: $(names[i]) edges=$(edges[i])"
    if edges[i] < expected-min[i] or edges[i] > expected-max[i]: failed = true

  pins.do: | pin/gpio.Pin | pin.close
  if failed:
    print "gpio-alt-esp32: FAIL edge count outside expected range"
  else:
    print "gpio-alt-esp32: PASS both ALT4 pads"
