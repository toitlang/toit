// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import gpio
import i2c

/**
Example to demonstrate the use of the I2C.
*/

SDA ::= 21
SCL ::= 22

main:
  print "Creating i2c bus"
  bus := i2c.Bus
      --sda=gpio.Pin SDA
      --scl=gpio.Pin SCL

  print "Scanning"
  found := bus.scan

  print "Found: $found.size devices"
  found.do:
    print "  $(%02x it)"
