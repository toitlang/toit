// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

fib n:
  a := 0
  b := 1
  n.repeat:
    t := a + b
    a = b
    b = t
  return a

main:
  print (fib 50)
  print (fib 90)
  x := 0x3fff_ffff
  print x + 1
  print x * x
  y := 0x7fff_ffff_ffff_ffff
  print y
  print -y - 1
  print (y >> 3)
  print (y >>> 60)
  print (1 << 62)
  print (1 << 63)
  print (-1 << 40)
  print 0xffff_ffff_ffff_ffff
  print (12345678901234 * 1000)
  print (12345678901234567 / 1000)
  print (12345678901234567 % 1000)
  print (-12345678901234567 % 1000)
  print (0x1234_5678_9abc_def0 & 0xffff_0000_ffff_0000)
  print (0x1234_5678_9abc_def0 | 0xf)
  print (0x1234_5678_9abc_def0 ^ -1)
  print (~0x1234_5678_9abc)
  print (1_000_000_000_000 < 1_000_000_000_001)
  print (1_000_000_000_000 == 1_000_000_000_000)
  print ((1 << 40) + (1 << 40))
  print 4611686018427387904
  print -4611686018427387905
  print ((1 << 62) / -1)
  big := 1
  20.repeat: big *= 7
  print big
  print (big.to-string --radix=16)
  print (int.parse "123456789012345678")
  print 0x7fff_ffff_ffff_ffff.stringify.size
  print (1 << 30)
  print (-(1 << 30) - 1)
