// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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

Model (HW-calibrated 2026-07-18): period = SCLH+SCLL+305 ticks of the
functional clock, with SCLH/SCLL floored at 67 ticks (the fast-mode
t_LOW minimum — smaller divisors make runt SCL phases that progressively
glitch real slaves). 26 MHz source covers ~32..59 kHz, the 51.2 MHz
source (gate-enabled on demand) up to the ~117 kHz ceiling. Requests
above the ceiling run at the ceiling. The final 46 kHz batch re-crosses
the source boundary downward, so both switch directions are exercised.

Run via the mini-jag tester:

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/i2c-speed-ec618.toit
*/

import ec618 show Ec618
import i2c

EMPTY-ADDRESS ::= 0x40
PROBES ::= 200
// SCL cycles per NACK probe: START + 8 address bits + NACK slot + STOP.
CYCLES-PER-PROBE ::= 11

failures := []

main:
  bus := Ec618.i2c0 --pull-up

  // [requested Hz, expected wire Hz after clamping to the model].
  configs := [
    [46_000, 46_000],
    [32_000, 32_000],
    [100_000, 100_000],
    [117_000, 116_600],
    [400_000, 116_600],  // Above the ceiling: runs at the ceiling.
    [46_000, 46_000],    // Back down: exercises the 51M->26M switch.
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

  // The wire component per probe is CYCLES-PER-PROBE * period; software
  // overhead is identical across batches EXCEPT that every NACK probe
  // quiesces, and recovery on the 51.2 MHz source costs ~70 us/probe more
  // than on 26 MHz (root gate-enable + power cycle) — which damps the
  // fast-pace deltas. These are pace-ORDER checks with that damping
  // baked into the thresholds (wire-time predictions per probe: 46k
  // 239 us, 32k 344 us, 100k 110 us, ceiling ~94 us).
  base := batches[0]
  check (batches[1] - base > 10) "32k slower than 46k (delta $(batches[1] - base) ms, want > 10)"
  check (base - batches[2] > 6) "100k faster than 46k (delta $(base - batches[2]) ms, want > 6)"
  check (base - batches[3] > 8) "ceiling faster than 46k (delta $(base - batches[3]) ms, want > 8)"
  check ((batches[3] - batches[4]).abs < 8) "400k clamps to the ceiling (|$(batches[3] - batches[4])| ms, want < 8)"
  check ((batches[5] - base).abs < 8) "return to 46k matches the first run (|$(batches[5] - base)| ms, want < 8)"

  if not failures.is-empty:
    print "i2c-speed-ec618: FAIL $failures"
    throw "i2c speed failed: $failures"
  print "i2c-speed-ec618: PASS requested frequencies change the wire pace"

check ok/bool label/string -> none:
  print "i2c-speed: $label $(ok ? "ok" : "FAIL")"
  if not ok: failures.add label
