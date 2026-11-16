// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import gpio
import system.power

// Set these for the board: nRF P1.00=32; original ESP32 GPIO33=33;
// EC618 PAD42=42. The defaults target the nRF board.
WAKE-PIN ::= 32
WAKE-HIGH ::= true
DISABLE-WAKE ::= false
TIMED ::= true
// Try WAKE-LEVEL on ESP32/nRF or WAKE-EDGE on EC618; the opposite must fail.
TRIGGER ::= power.WAKE-AUTO

main:
  print "WAKE PROBE reset flags=$(power.reset-reason)"
  expect power.supports-timed-deep-sleep
  expect-throw "INVALID_ARGUMENT":
    power.configure-wakeup-pin -1
  expect-throw "INVALID_ARGUMENT":
    power.configure-wakeup-pin WAKE-PIN --pull-up --pull-down
  // Keep the pin owned through shutdown: wake setup must survive GPIO cleanup.
  pin := gpio.Pin WAKE-PIN --input --pull-down=WAKE-HIGH --pull-up=(not WAKE-HIGH)
  power.configure-wakeup-pin WAKE-PIN
      --trigger=TRIGGER
      --wake-high=WAKE-HIGH
      --pull-down=WAKE-HIGH
      --pull-up=(not WAKE-HIGH)
  if DISABLE-WAKE: power.disable-wakeup-pin WAKE-PIN
  print "WAKE PROBE pin=$WAKE-PIN level=$(pin.get) high=$WAKE-HIGH disabled=$DISABLE-WAKE"
  // Allow an operator to release the input before the next sleep.
  sleep --ms=5000
  print "WAKE PROBE sleeping timed=$TIMED"
  if TIMED: power.deep-sleep (Duration --s=30)
  power.deep-sleep
