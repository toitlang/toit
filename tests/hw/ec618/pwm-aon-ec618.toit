// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
EC618 half of the AON-pad PWM test (device under test).

The module's "PWM01"/"PWM04" silkscreen pins are real AP-timer PWM
routes: the SDK's luat_pwm_ec618.c maps PWM channel 1 (TIMER1) to PAD44
and channel 4 (TIMER4) to PAD47 (RTE_PWM1/RTE_PWM4 in the SDK project
configs), iomux ALT5 like every other PWM pad — the pads just live in
the AON domain, so the driver powers the AON IO LDO first.

This is also the first HW exercise of TIMER1's PWM (the base pwm test
could only reach TIMER0/TIMER4 wires). Phases:

1. PAD44 (TIMER1) alone: 1 kHz frequency + duty 0.25/0.75 at 10 Hz.
2. PAD47 (TIMER4) alone: 1 kHz frequency.
3. Both simultaneously — from TWO generators at different rates — then
   closing PAD44's channel silences it while PAD47 keeps running.

MEASURED RIG QUIRK (2026-07-02): when BOTH AON pads drive, edge counts
on the pin-18 wire include the pin-27 wire's transitions (1 kHz + 1 kHz
counted ~2023 Hz; 1 kHz + 700 Hz counted ~1338 Hz; alone it is exact,
and it snaps back the moment the other channel closes). The coupled
pulses survive the ESP32 counter's maximum ~12.7 us glitch filter, so
they are real us-scale level shifts — plausibly AON-rail bounce between
the two (shared-LDO, modest-drive) AON output cells, or breadboard
coupling; one-channel counts and polled duty are unaffected. The
simultaneous phase therefore asserts PAD44 by DUTY (polling is immune)
and PAD47 by count.

Wiring: EC618 UART2 (PAD26 -> IO27, IO14 -> PAD25) = command lane;
        EC618 PAD44 (PWM ch1, board pin 18) -> ESP32 IO19;
        EC618 PAD47 (PWM ch4, board pin 27) -> ESP32 IO2.

Run via the mini-jag tester (start pwm-esp32.toit on the ESP32 FIRST):

  build/host/sdk/bin/toit tests/hw/esp-tester/tester.toit run \
      --chip ec618 --toit-exe build/host/sdk/bin/toit \
      --port-board1 <ec618-uart0-port> tests/hw/ec618/pwm-aon-ec618.toit
*/

import ec618 show Ec618
import gpio.pwm show Pwm PwmChannel
import uart

IO-PAD44 ::= 19  // ESP32 pin watching PAD44 (board pin 18).
IO-PAD47 ::= 2   // ESP32 pin watching PAD47 (board pin 27).

failures := []

main:
  control := Ec618.uart2 --baud-rate=115200

  // Phase 1: PAD44 = TIMER1 — frequency and duty.
  generator := Pwm --frequency=1000
  channel := generator.start (Ec618.pad 44) --duty-factor=0.5
  expect-hz control IO-PAD44 1000 "pad44-1kHz"
  channel.close
  generator.close

  generator = Pwm --frequency=10
  channel = generator.start (Ec618.pad 44) --duty-factor=0.25
  expect-duty control IO-PAD44 250 "pad44-duty-0.25"
  channel.set-duty-factor 0.75
  expect-duty control IO-PAD44 750 "pad44-duty-0.75"
  channel.close
  generator.close

  // Phase 2: PAD47 = TIMER4.
  generator = Pwm --frequency=1000
  channel = generator.start (Ec618.pad 47) --duty-factor=0.5
  expect-hz control IO-PAD47 1000 "pad47-1kHz"
  channel.close
  generator.close

  // Phase 3: both AON PWM pins at once (TIMER1 + TIMER4), two
  // generators at different rates. PAD44 is asserted by DUTY — edge
  // counts on its wire double-count the neighbor's transitions while
  // both drive (see the rig quirk above).
  generator = Pwm --frequency=10
  channel = generator.start (Ec618.pad 44) --duty-factor=0.25
  generator47 := Pwm --frequency=1000
  channel47 := generator47.start (Ec618.pad 47) --duty-factor=0.5
  expect-duty control IO-PAD44 250 "both-pad44-duty"
  expect-hz control IO-PAD47 1000 "both-pad47"
  channel.close
  expect-level control IO-PAD44 0 "closed-pad44-silent"
  expect-hz control IO-PAD47 1000 "pad47-still-alive"
  channel47.close
  generator47.close
  generator.close

  control.out.write "Q\n"
  control.close

  if not failures.is-empty:
    print "pwm-aon-ec618: FAIL $failures"
    throw "AON PWM test failed: $failures"
  print "pwm-aon-ec618: PASS"

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
  print "pwm-aon-ec618: $label $(ok ? "ok" : "FAIL") (measured $(measured.to-int) Hz, want $hz)"
  if not ok: failures.add label

// Asks for a polled duty measurement (permille) and checks within ±50‰.
expect-duty control/uart.Port io/int permille/int label/string -> none:
  reply := exchange control "D $io"        // -> "D <high-permille>"
  measured := int.parse reply[1]
  ok := (measured - permille).abs <= 50
  print "pwm-aon-ec618: $label $(ok ? "ok" : "FAIL") (measured $(measured)‰, want $permille‰)"
  if not ok: failures.add label

// Asks for a level+edges probe and checks the line is constant at `level`.
expect-level control/uart.Port io/int level/int label/string -> none:
  reply := exchange control "L $io"        // -> "L <level> <edges>"
  got-level := int.parse reply[1]
  edges := int.parse reply[2]
  ok := got-level == level and edges == 0
  print "pwm-aon-ec618: $label $(ok ? "ok" : "FAIL") (level $got-level, $edges edges)"
  if not ok: failures.add label
