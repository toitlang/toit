// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import math

main:
  print 1.5
  print 0.1 + 0.2
  print 1.0 / 3.0
  print 2.0 * 3.5
  print 10.0 - 0.25
  print 1e21
  print 1e-7
  print 123456.789e3
  print -0.0
  print (0.0 / 0.0)
  print (1.0 / 0.0)
  print (-1.0 / 0.0)
  print 3.7.round
  print 3.2.floor
  print 3.2.ceil
  print (-3.7).truncate
  print (math.sqrt 2.0)
  print (math.pow 2.0 10.0)
  print (math.sin 0.0)
  print 2.5.to-int
  print 7.to-float
  print (1 + 0.5)
  print (0.5 + 1)
  print (3 < 3.5)
  print (3.5 < 3)
  print (2.0 == 2)
  print (float.parse "3.25")
  print (float.parse "-1e3")
  print (3.14159.to-string --precision=2)
  print (1.0).sign
  print (-2.0).sign
  print (0.0 / 0.0).is-nan
  print 100.0.is-finite
  print (5.5 % 2.0)
  print (1.0e300 * 1.0e10)
  print 1.7976931348623157e308
  print 5e-324
  print [1.5, 0.5, 2.5].sort
  print (max 2.5 1.5)
  print (min 2.5 1.5)
  print 0.1.bits
  print (float.from-bits 0x3ff8000000000000)
  sum := 0.0
  10.repeat: sum += 0.1
  print sum
  print (sum == 1.0)
  print 1e15
  print 1e16
  print 123456789012345680000.0
