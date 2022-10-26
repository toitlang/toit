// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
Example to show how to trigger a device to resume from deep
  sleep and execute application code based on the touchpad
  functionality.

Setup: Connect a jumper wire to pin 32.

Start the program, and let the device go into deep sleep.
Touch pin 32. The device should wake up again.
*/

import gpio
import gpio.touch as gpio
import esp32

TOUCH_CALIBRATION_ITERATIONS ::= 16
TOUCH_PIN ::= 32

main:
  if esp32.wakeup_cause == esp32.WAKEUP_TOUCHPAD:
    print "Woken up from touchpad"
    // Chances are that when we just woke up because of registered
    // touch, it is the wrong time to re-calibrate because you might
    // still be touching the pin. Sleep for a little while to increase
    // the chance of getting the calibration right :)
    sleep --ms=1_000
  else:
    print "Woken up for other reasons"

  // Before using touch, we need to calibrate it. This also applies to
  // the 'wakeup' which will trigger on any unclosed touch pins after
  // calling $esp32.enable_touchpad_wakeup when going into deep sleep.
  touch := gpio.Touch (gpio.Pin TOUCH_PIN)
  calibrate touch

  // Calibrated. Let's report the threshold and read it!
  print "Pin $TOUCH_PIN: $touch.threshold $(touch.read --raw)"
  esp32.enable_touchpad_wakeup

  // Now, the touch pin is still open and we've enabled touch 'wakeup'.
  // The device will wakeup in 30 seconds (for other reasons) unless
  // we touch it before then.
  esp32.deep_sleep (Duration --s=30)

calibrate touch/gpio.Touch -> none:
  sum := 0
  TOUCH_CALIBRATION_ITERATIONS.repeat:
    sum += touch.read --raw
  touch.threshold = sum * 2 / (3 * TOUCH_CALIBRATION_ITERATIONS)
