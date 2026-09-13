// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618 show Ec618
import gpio.pwm show Pwm PwmChannel
import uart

import .wiring as wiring

/**
EC618 half of the PWM test (device under test).

Drives PWM and asks the ESP32 helper to measure it, over UART2 as a
  command/response lane (UART2 is free: the PWM outputs live on other pads).
  Phases:

1. Frequency: 1 kHz, duty 0.5 on PAD33 (TIMER4) — the ESP32 counts rising
   edges over ~2 s.
2. Duty: 10 Hz; duty factors 0.25/0.5/0.75 sampled by polling, plus the
   exact static 0.0 and 1.0 endpoints.
3. Endpoint waveform: a 20 MHz ESP32 RMT capture distinguishes exact static
   levels from the short periodic notch formerly emitted for 1.0.
4. set-frequency: one generator moved 1 kHz -> 2 kHz, re-measured.
5. Two channels: TIMER4/PAD33 and TIMER0/PAD16 from one generator, both
   measured; closing one channel silences it while the other keeps going.
   (PAD16 is the pad behind the board's "GPIO01/PWM10" pin -> ESP32 IO23;
   this phase doubles as the experimental confirmation of that wire.)
6. Running with the argument `leak` exits with TIMER4/PAD33 active. A
   following normal run first verifies that forced container teardown stopped
   the output and returned the timer lease.

All assertions happen here; the helper only measures.

*/

failures := []

main args:
  if not args.is-empty and args[0] == "leak":
    leaked := Pwm --frequency=1000
    leaked-channel := leaked.start wiring.EC618-TIMER4-PAD --duty-factor=0.5
    print "pwm-ec618: leaving TIMER4/PAD$(wiring.EC618-TIMER4-PAD) active for container-teardown coverage ($leaked-channel)"
    return

  control := Ec618.uart2 --baud-rate=115200
  timer4-pad := wiring.EC618-TIMER4-PAD
  timer0-pad := wiring.EC618-TIMER0-PAD

  // Phase 1: forced teardown from a preceding leak run left the output
  // released and returned both the pad and TIMER4, so they can be acquired
  // immediately.
  expect-level control wiring.ESP32-TIMER4-PIN 0 "initially-silent"
  generator := Pwm --frequency=1000
  channel := generator.start timer4-pad --duty-factor=0.5
  expect-hz control wiring.ESP32-TIMER4-PIN 1000 "1kHz"
  channel.close
  generator.close

  // Phase 2: duty factors at 10 Hz (slow enough for polled sampling).
  generator = Pwm --frequency=10
  channel = generator.start timer4-pad --duty-factor=0.25
  expect-duty control wiring.ESP32-TIMER4-PIN 250 "duty-0.25"
  channel.set-duty-factor 0.5
  expect-duty control wiring.ESP32-TIMER4-PIN 500 "duty-0.50"
  channel.set-duty-factor 0.75
  expect-duty control wiring.ESP32-TIMER4-PIN 750 "duty-0.75"
  channel.set-duty-factor 0.0
  expect-level control wiring.ESP32-TIMER4-PIN 0 "duty-0"
  channel.set-duty-factor 1.0
  expect-level control wiring.ESP32-TIMER4-PIN 1 "duty-1"
  // Coming back from either static endpoint must restore timer PWM.
  channel.set-duty-factor 0.5
  expect-duty control wiring.ESP32-TIMER4-PIN 500 "duty-recover"
  channel.close
  generator.close

  // Phase 3: an armed low-to-high transition proves that 100% becomes
  // truly static. The former notched output would keep the RMT capture busy.
  generator = Pwm --frequency=10_000
  channel = generator.start timer4-pad --duty-factor=0.0
  expect-nonstatic-rmt
      control
      channel
      wiring.ESP32-TIMER4-PIN
      "rmt-pwm-positive-control"
  channel.set-duty-factor 0.0
  expect-static-high-rmt
      control
      channel
      wiring.ESP32-TIMER4-PIN
      "rmt-duty-1"
  channel.set-duty-factor 0.5
  expect-hz control wiring.ESP32-TIMER4-PIN 10_000 "rmt-recover-from-1"
  channel.close
  generator.close

  // Phase 4: live frequency change on the generator.
  generator = Pwm --frequency=1000 --max-frequency=8000
  channel = generator.start timer4-pad --duty-factor=0.5
  generator.frequency = 2000
  if generator.frequency != 2000: failures.add "frequency-readback"
  expect-hz control wiring.ESP32-TIMER4-PIN 2000 "2kHz"
  channel.close
  generator.close

  // Phase 5: two channels (two timers) from one generator.
  generator = Pwm --frequency=1000
  channel = generator.start timer4-pad --duty-factor=0.5
  channel16 := generator.start timer0-pad --duty-factor=0.5
  expect-hz control wiring.ESP32-TIMER4-PIN 1000 "two-ch-pad33"
  expect-hz control wiring.ESP32-TIMER0-PIN 1000 "two-ch-pad16"
  channel.close
  expect-level control wiring.ESP32-TIMER4-PIN 0 "closed-ch-silent"
  expect-hz control wiring.ESP32-TIMER0-PIN 1000 "other-ch-alive"
  channel16.close
  generator.close

  control.out.write "Q\n"
  control.close
  if not failures.is-empty:
    print "pwm-ec618: FAIL $failures"
    throw "PWM test failed: $failures"
  print "pwm-ec618: PASS"

// Sends a command and reads one newline-terminated reply.
exchange control/uart.Port command/string -> List:
  control.out.write "$command\n"
  return read-reply control

// Reads one newline-terminated helper reply.
read-reply control/uart.Port -> List:
  line := ""
  buffer := #[]
  with-timeout --ms=15_000:
    while true:
      nl := buffer.index-of '\n'
      if nl >= 0:
        line = buffer[..nl].to-string.trim
        break
      chunk := control.in.read
      if chunk == null: throw "control lane closed"
      buffer += chunk
  return line.split " "

// Asks for an edge count on the given ESP32 pin and checks the measured
// frequency is within 10%.
expect-hz control/uart.Port io/int hz/int label/string -> none:
  reply := exchange control "F $io"        // -> "F <edges> <elapsed-us>"
  edges := int.parse reply[1]
  elapsed-us := int.parse reply[2]
  measured := edges * 1_000_000.0 / elapsed-us
  ok := measured > hz * 0.9 and measured < hz * 1.1
  print "pwm-ec618: $label $(ok ? "ok" : "FAIL") (measured $(measured.to-int) Hz, want $hz)"
  if not ok: failures.add label

// Asks for a polled duty measurement (permille) and checks within ±50‰.
expect-duty control/uart.Port io/int permille/int label/string -> none:
  reply := exchange control "D $io"        // -> "D <high-permille>"
  measured := int.parse reply[1]
  ok := (measured - permille).abs <= 50
  print "pwm-ec618: $label $(ok ? "ok" : "FAIL") (measured $(measured)‰, want $permille‰)"
  if not ok: failures.add label

// Asks for a level+edges probe and checks the line is constant at `level`.
expect-level control/uart.Port io/int level/int label/string -> none:
  reply := exchange control "L $io"        // -> "L <level> <edges>"
  got-level := int.parse reply[1]
  edges := int.parse reply[2]
  ok := got-level == level and edges == 0
  print "pwm-ec618: $label $(ok ? "ok" : "FAIL") (level $got-level, $edges edges)"
  if not ok: failures.add label

// Arms RMT while low, then switches to 100%. Exact high produces one edge
// followed by idle; the former periodic notch never reaches that idle state.
expect-static-high-rmt
    control/uart.Port
    channel/PwmChannel
    io/int
    label/string
    -> none:
  ready := exchange control "A $io"
  if ready != ["A", "READY"]:
    failures.add "$(label)-arm"
    return
  channel.set-duty-factor 1.0
  reply := read-reply control
  timed-out := int.parse reply[1]
  got-level := int.parse reply[2]
  signals := int.parse reply[3]
  low-signals := int.parse reply[4]
  shortest-low-ns := int.parse reply[5]
  ok := timed-out == 0 and got-level == 1 and signals <= 2
  print "pwm-ec618: $label $(ok ? "ok" : "FAIL") (timeout $timed-out, level $got-level, $signals RMT signals, $low-signals low, shortest $(shortest-low-ns)ns)"
  if not ok: failures.add label

// Proves that a periodic waveform does not satisfy the endpoint oracle.
expect-nonstatic-rmt
    control/uart.Port
    channel/PwmChannel
    io/int
    label/string
    -> none:
  ready := exchange control "A $io"
  if ready != ["A", "READY"]:
    failures.add "$(label)-arm"
    return
  channel.set-duty-factor 0.5
  reply := read-reply control
  timed-out := int.parse reply[1]
  got-level := int.parse reply[2]
  signals := int.parse reply[3]
  low-signals := int.parse reply[4]
  shortest-low-ns := int.parse reply[5]
  ok := timed-out == 1 or signals > 2
  print "pwm-ec618: $label $(ok ? "ok" : "FAIL") (timeout $timed-out, level $got-level, $signals RMT signals, $low-signals low, shortest $(shortest-low-ns)ns)"
  if not ok: failures.add label
