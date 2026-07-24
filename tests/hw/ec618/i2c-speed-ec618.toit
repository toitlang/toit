// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import i2c

/**
EC618 I2C wire-pace regression: requested device frequencies must change
  the wire speed (the calibrated TPR model in i2c_ec618.cc).

Runs on the EMPTY I2C0 bus (pads 14/13, internal pull-ups) — no slave
  needed: each probe of an absent address clocks ~11 SCL cycles before the
  NACK, so batch duration tracks the wire pace. A device transfer first
  makes its frequency the bus's sticky probe pace; the batches then use
  $i2c.Bus.test — the tight synchronous spin path (~350 us/probe) — so the
  wire component dominates. Software overhead is identical across batches
  and cancels in the deltas; the platform clock ticks in 1 ms steps, hence
  batches instead of per-probe timing.

Model (HW-calibrated 2026-07-18 with ESP32 RMT): the bounded linear region
  has period `2*SCLx+20` functional-clock ticks. The 26 MHz source covers
  through ~206 kHz and the gate-enabled 51.2 MHz source handles intermediate
  fast requests. At 400 kHz the driver switches to the LuatOS-style full timing
  word on 26 MHz; the fastest bounded SCLx=30 variant measures ~363 kHz. SCLx=28
  free-runs an address-NACK command. Higher requests clamp to the safe setting.
  The final 50 kHz batch re-crosses the source boundary downward.

Run via the mini-jag tester:

```
  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/i2c-speed-ec618.toit
```
*/

EMPTY-ADDRESS ::= 0x40
PROBES ::= 200

failures := []

main:
  bus := Ec618.i2c0 --pull-up

  // [requested Hz, approximate wire Hz after clamping to the model].
  configs := [
    [50_000, 50_000],
    [100_000, 100_000],
    [200_000, 200_000],
    [330_000, 330_000],
    [400_000, 363_000],
    [1_000_000, 363_000],  // Above the ceiling: same safe setting.
    [50_000, 50_000],      // Back down: exercises the 51M->26M switch.
  ]

  batches := []
  configs.do: | config/List |
    requested := config[0]
    device := bus.device EMPTY-ADDRESS --frequency=requested
    // The device transfer makes $requested the sticky probe pace (and
    // performs any source switch); the timed probes then ride it.
    3.repeat: catch: device.read 1
    start := Time.monotonic-us
    PROBES.repeat: bus.test EMPTY-ADDRESS
    duration-ms := (Time.monotonic-us - start) / 1000
    device.close
    batches.add duration-ms
    print "i2c-speed: $(%6d requested) Hz requested -> $(%4d duration-ms) ms / $PROBES probes"

  bus.close

  // Software overhead is identical across batches except that every NACK
  // probe quiesces. These are deliberately broad pace-order/clamp checks;
  // RMT is the wire-side frequency oracle.
  base := batches[0]
  check (base - batches[1] > 12) "100k faster than 50k (delta $(base - batches[1]) ms, want > 12)"
  check (batches[1] - batches[2] > 4) "200k faster than 100k (delta $(batches[1] - batches[2]) ms, want > 4)"
  check (batches[2] - batches[3] > 1) "330k faster than 200k (delta $(batches[2] - batches[3]) ms, want > 1)"
  check (batches[4] <= batches[3] + 5) "400k no slower than 330k (delta $(batches[4] - batches[3]) ms, want <= 5)"
  check ((batches[4] - batches[5]).abs < 6) ">400k clamps to 400k (|$(batches[4] - batches[5])| ms, want < 6)"
  check ((batches[6] - base).abs < 8) "return to 50k matches the first run (|$(batches[6] - base)| ms, want < 8)"

  if not failures.is-empty:
    print "i2c-speed-ec618: FAIL $failures"
    throw "i2c speed failed: $failures"
  print "i2c-speed-ec618: PASS requested frequencies change the wire pace"

check ok/bool label/string -> none:
  print "i2c-speed: $label $(ok ? "ok" : "FAIL")"
  if not ok: failures.add label
