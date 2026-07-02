// Copyright (C) 2026 Toit contributors.

/**
EC618 half of the GPIO22 (PAD42 = wakeup pad 5) deep-sleep wake test.

Pair with wakeup-gpio22-esp32.toit on the ESP32 (its IO13 is wired to
GPIO22, board pin 9; the BMP280 must be unplugged so the net is a clean
point-to-point wire). The helper holds the net low, waits 60s for this
side to hibernate, then pulses it.

Armed for both edges with an internal pull-down, a pulse must end the
hibernate early: the device reboots after ~60s (not the full 150s RTC
fallback) and the boot after the sleep reports wake=pad (the mini-jag
banner and ec618.wakeup-cause).

The harness reports "did not pass" by design — the device reboots
instead of exiting 0. The verdict is the wake cause + the timing of the
boot that follows.
*/

import ec618
import gpio

// Bring-up sequence variants (see arm_wakeup_pads in toit_ec618.cc).
// 0 = the canonical sequence: NVIC enable + slpManSetWakeupPadCfg.
ARM-FLAGS ::= 0

GPIO22-WAKEUP-PAD ::= 5  // GPIO22 = PAD42 = wakeup pad 5.

main:
  print "reset=$(ec618.reset-reason-name ec618.reset-reason) wake=$(ec618.wakeup-cause-name ec618.wakeup-cause)"
  print "wupins=0b$(%b ec618.wakeup-pin-values)"

  // Wire health: the ESP32 helper holds the net low before pulsing.
  pin := gpio.Pin 42 --input
  print "gpio22=$pin.get (expect 0 while the helper holds the net low)"
  pin.close

  ec618.wakeup-arm-flags_ ARM-FLAGS
  ec618.configure-wakeup-pad GPIO22-WAKEUP-PAD --pos-edge --neg-edge --pull-down
  print "Going to deep sleep for 150s; a GPIO22 edge should wake us early..."
  ec618.deep-sleep (Duration --s=150)
  print "ERROR: deep-sleep returned!"
