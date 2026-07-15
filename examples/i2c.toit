// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import i2c

/**
Example to demonstrate the use of the I2C.
*/

SDA ::= 21
SCL ::= 22

main:
  print "Creating i2c bus"
  bus := i2c.Bus
      --sda=SDA
      --scl=SCL

  print "Scanning"
  found := bus.scan

  print "Found: $found.size devices"
  found.do:
    print "  $(%02x it)"
