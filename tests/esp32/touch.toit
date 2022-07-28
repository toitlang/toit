// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the wakeup functionality of the touch pad.

Setup:
Optionally connect a jumper wire to pin 32.
Do the same for pin 33.

Start the program, and let the device go into deep sleep.
Touch pin 33. The device should *not* wake up, as the pin was closed.
Touch pin 32. The device should wake up again.
*/

import gpio
import gpio.touch as gpio
import esp32

calibrate touch/gpio.Touch:
  CALIBRATION_ITERATIONS ::= 16

  sum := 0
  CALIBRATION_ITERATIONS.repeat:
    sum += touch.read --raw
  touch.threshold = sum * 2 / (3 * CALIBRATION_ITERATIONS)

main:
  if esp32.wakeup_cause == esp32.WAKEUP_TOUCHPAD:
    print "Woken up from touchpad"
    print esp32.touchpad_wakeup_status
  else:
    touch32 := gpio.Touch (gpio.Pin 32)
    calibrate touch32
    print "pin 32: $touch32.threshold $(touch32.read --raw)"

    touch33 := gpio.Touch (gpio.Pin 33)
    calibrate touch33
    print "pin 33: $touch33.threshold $(touch33.read --raw)"
    touch33.close

    print "going into deep sleep"
    esp32.enable_touchpad_wakeup
    esp32.deep_sleep (Duration --s=10)
