// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests the wakeup functionality of the touch pad.

For the setup see the comment near $Variant.touch-pin1.

Start the program, and let the device go into deep sleep.
Touch pin 4. The device should *not* wake up, as the pin was closed.
Touch pin 2. The device should wake up again.
*/

import gpio
import gpio.touch as gpio
import esp32

import .variants

TOUCH-PIN1 ::= Variant.CURRENT.touch-pin1
TOUCH-PIN2 ::= Variant.CURRENT.touch-pin2

calibrate touch/gpio.Touch:
  CALIBRATION-ITERATIONS ::= 16

  sum := 0
  CALIBRATION-ITERATIONS.repeat:
    sum += touch.read --raw
  touch.threshold = sum * 2 / (3 * CALIBRATION-ITERATIONS)

main:
  pin1-desc := "$TOUCH-PIN1 (yellow)"
  pin2-desc := "$TOUCH-PIN2 (green)"
  if esp32.wakeup-cause == esp32.WAKEUP-TOUCHPAD:
    print "Woken up from touchpad"
    print esp32.touchpad-wakeup-status
  else:
    touch1 := gpio.Touch (gpio.Pin TOUCH-PIN1)
    calibrate touch1
    print "pin $pin1-desc: $touch1.threshold $(touch1.read --raw)"

    touch2 := gpio.Touch (gpio.Pin TOUCH-PIN2)
    calibrate touch2
    print "pin $pin2-desc: $touch2.threshold $(touch2.read --raw)"

    print "waiting for touch on pin $pin1-desc"
    while not touch1.get: sleep --ms=1

    print "waiting for touch on pin $pin2-desc"
    while not touch2.get: sleep --ms=1

    touch2.close

    print "going into deep sleep"
    sleep --ms=500
    print "ESP32 should not wake up from pin $pin2-desc, but should wake up from pin $pin1-desc"
    esp32.enable-touchpad-wakeup
    esp32.deep-sleep (Duration --s=10)
