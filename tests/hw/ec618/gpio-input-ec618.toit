// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import ec618 show Ec618

/**
EC618 half of the GPIO-input HW test (device under test).

The reverse of gpio-output: the ESP32 (gpio-input-esp32.toit) drives a square
  wave and the EC618 reads it as a GPIO input. This validates the receive
  direction (ESP32 -> EC618), which is safe now that the EC618 IO rail is 3.3 V
  (see docs/ec618-hw-tests.md "Voltage domains"). The EC618 configures GPIO11
  (PAD26) as input only — it never drives the line, so there is no contention with
  the ESP32 output.

Passes if the EC618 sees the square wave: both levels and enough edges.

Wiring (NOTE: gpio.Pin numbers are PAD numbers on EC618): ESP32 IO27 -> EC618 board pin 5 (PAD26 = GPIO11).

Run via the mini-jag tester (start gpio-input-esp32.toit on the ESP32 first):

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/gpio-input-ec618.toit
```
*/

GPIO-EC618 ::= 11               // Primary PAD26, driven by ESP32 IO27.
SAMPLE ::= Duration --ms=2      // Poll fast enough to catch a 10 Hz square wave.
WINDOW ::= Duration --s=20      // Sample window. We configure the pad as INPUT first
                                // (so the ESP32 can start driving without contention),
                                // and the ESP32 begins a few seconds into this window.
MIN-EDGES ::= 30                // A 10 Hz wave over the overlap gives 100s of edges.

main:
  pin := Ec618.gpio GPIO-EC618
  pin.configure --input
  print "gpio-input-ec618: reading GPIO$GPIO-EC618 (driven by ESP32) for $(WINDOW.in-s)s"
  last := pin.get
  saw0 := last == 0
  saw1 := last == 1
  edges := 0
  deadline := Time.monotonic-us + WINDOW.in-us
  while Time.monotonic-us < deadline:
    v := pin.get
    if v != last:
      edges++
      last = v
    if v == 0: saw0 = true else: saw1 = true
    sleep SAMPLE
  pin.close

  print "gpio-input-ec618: edges=$edges saw0=$saw0 saw1=$saw1"
  if edges >= MIN-EDGES and saw0 and saw1:
    print "gpio-input-ec618: PASS EC618 reads the ESP32-driven wave (ESP32->EC618 works at 3.3 V)"
  else:
    print "gpio-input-ec618: FAIL did not track the ESP32 drive (expected >= $MIN-EDGES edges + both levels)"
    throw "GPIO input did not track the ESP32 drive"
