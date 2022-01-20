// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  print -0x0
  print -0b0
  print 0x1_0000_0000_0000_0000
  print 0b1_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000
  print 9223372036854775808
  print -9223372036854775809
