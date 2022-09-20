// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
Example to show how to trigger a device to resume from deep
  sleep and execute application code based on the wake-on-pin
  functionality.

Setup: Use a pull-down resistor to pull pin 32 to ground.

Start the program, and let the device go into deep sleep.

Connect pin 32 to 3.3V. The device should wake up again.
*/

import gpio
import esp32

WAKEUP_PIN ::= 32

main:
  if esp32.wakeup_cause == esp32.WAKEUP_EXT1:
    print "Woken up from external pin"
    // Chances are that when we just woke up because a pin went high.
    // Give the pin a chance to go low again.
    sleep --ms=1_000
  else:
    print "Woken up for other reasons: $esp32.wakeup_cause"

  pin := gpio.Pin WAKEUP_PIN
  mask := 0
  mask |= 1 << pin.num

  esp32.enable_external_wakeup mask true

  print "Sleeping for up to 30 seconds"
  esp32.deep_sleep (Duration --s=30)
