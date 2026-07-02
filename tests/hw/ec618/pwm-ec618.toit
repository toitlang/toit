// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the PWM test (device under test).

Drives PWM and asks the ESP32 helper to measure it, over UART2 as a
command/response lane (UART2 is free: the PWM outputs live on other pads).
Phases:

1. Frequency: 1 kHz, duty 0.5 on PAD33 (TIMER4) — the ESP32 counts rising
   edges over ~2 s.
2. Duty: 10 Hz; duty factors 0.25/0.5/0.75 sampled by polling, plus the
   extremes 0.0 (constant low, no edges) and 1.0 (high — on the EC618 a
   true constant high is not expressible in PWM mode; the driver emits a
   single 38 ns low notch per period, invisible to the polled probe).
3. set-frequency: one generator moved 1 kHz -> 2 kHz, re-measured.
4. Two channels: TIMER4/PAD33 and TIMER0/PAD16 from one generator, both
   measured; closing one channel silences it while the other keeps going.
   (PAD16 is the pad behind the board's "GPIO01/PWM10" pin -> ESP32 IO23;
   this phase doubles as the experimental confirmation of that wire.)

All assertions happen here; the helper only measures.

Wiring: EC618 UART2 (PAD26 -> IO27, IO14 -> PAD25) = command lane;
        EC618 PAD33 (PWM, TIMER4) -> IO16; EC618 PAD16 (PWM, TIMER0) -> IO23.

Run via the mini-jag tester (start pwm-esp32.toit on the ESP32 FIRST):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/pwm-ec618.toit
*/

import ec618 show Ec618
import gpio.pwm show Pwm PwmChannel
import uart

IO-PAD33 ::= 16  // ESP32 pin watching PAD33.
IO-PAD16 ::= 23  // ESP32 pin watching PAD16.

failures := []

main:
  control := Ec618.uart2 --baud-rate=115200

  // Phase 1: frequency.
  generator := Pwm --frequency=1000
  channel := generator.start (Ec618.pad 33) --duty-factor=0.5
  expect-hz control IO-PAD33 1000 "1kHz"
  channel.close
  generator.close

  // Phase 2: duty factors at 10 Hz (slow enough for polled sampling).
  generator = Pwm --frequency=10
  channel = generator.start (Ec618.pad 33) --duty-factor=0.25
  expect-duty control IO-PAD33 250 "duty-0.25"
  channel.set-duty-factor 0.5
  expect-duty control IO-PAD33 500 "duty-0.50"
  channel.set-duty-factor 0.75
  expect-duty control IO-PAD33 750 "duty-0.75"
  channel.set-duty-factor 0.0
  expect-level control IO-PAD33 0 "duty-0"
  channel.set-duty-factor 1.0
  expect-level control IO-PAD33 1 "duty-1"
  // Coming back from the extremes must work too (0.0 is a hardware trap:
  // leaving it needs the driver's timer restart).
  channel.set-duty-factor 0.5
  expect-duty control IO-PAD33 500 "duty-recover"
  channel.close
  generator.close

  // Phase 3: live frequency change on the generator.
  generator = Pwm --frequency=1000 --max-frequency=8000
  channel = generator.start (Ec618.pad 33) --duty-factor=0.5
  generator.frequency = 2000
  if generator.frequency != 2000: failures.add "frequency-readback"
  expect-hz control IO-PAD33 2000 "2kHz"
  channel.close
  generator.close

  // Phase 4: two channels (two timers) from one generator.
  generator = Pwm --frequency=1000
  channel = generator.start (Ec618.pad 33) --duty-factor=0.5
  channel16 := generator.start (Ec618.pad 16) --duty-factor=0.5
  expect-hz control IO-PAD33 1000 "two-ch-pad33"
  expect-hz control IO-PAD16 1000 "two-ch-pad16"
  channel.close
  expect-level control IO-PAD33 0 "closed-ch-silent"
  expect-hz control IO-PAD16 1000 "other-ch-alive"
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
