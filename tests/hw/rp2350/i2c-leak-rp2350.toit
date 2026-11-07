// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import i2c

/** Leaves I2C0 open so container teardown must release its controller/pins. */
main:
  i2c.Bus --sda=4 --scl=5 --frequency=100_000 --pull-up
  print "i2c-leak-rp2350: leaving I2C0 open"
