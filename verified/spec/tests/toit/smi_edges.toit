// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Edge cases of the smi fast paths in the interpreter.

main:
  min := -(1 << 62)  // MIN_SMI on 64-bit.
  // MIN_SMI / -1 is 2^62, a large integer. The INVOKE_DIV fast path used to
  // wrap it back to MIN_SMI on 64-bit; it now leaves it to the slow path
  // (see DESIGN.md).
  print min / -1
  print min % -1
  print min * -1
  print min - 1
  print -min
  print (min >> 70)
  print (min >>> 1)
  print (1 << 61) + (1 << 61)
  print 0x3fff_ffff_ffff_ffff + 1
  print (0x3fff_ffff_ffff_ffff * 2)
  print (-7 / 2)
  print (-7 % 2)
  print (7 % -2)
  print (5 << 0)
  print (1 << 64)
  print (-1 >> 63)
  print (12 & -4)
  print (12 | -16)
  print (12 ^ -1)
