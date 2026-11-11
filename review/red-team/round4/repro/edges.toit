// Copyright (C) 2026 Toit contributors.
// Red-team round 4, line C: word-size edge behavior. One program that prints
// deterministic results of computations around smi/large-int, length and
// hash boundaries. Output must be byte-identical on the 64-bit and 32-bit
// host builds run with --untrusted (the only documented differences are
// system.BITS-PER-WORD / architecture, which this program avoids).
import math

show x/any -> none:
  print x

main:
  // Smi boundary on 32-bit is 2^30-1; on 64-bit 2^62-1. Values that cross the
  // 32-bit smi boundary become large integers on 32-bit but stay smi on
  // 64-bit; arithmetic results must still match.
  a := 1073741823                 // 2^30 - 1 (max smi on 32-bit)
  b := 1073741824                 // 2^30
  c := 4611686018427387903        // 2^62 - 1 (max smi on 64-bit)
  d := 4611686018427387904        // 2^62
  show a
  show b
  show (a + 1)
  show (b - 1)
  show (b * b)                    // 2^60, large int on 32-bit
  show c
  show (c + 1)
  show d
  show (d * 2)
  show (-1073741824)              // min-ish
  show (-4611686018427387904)
  show (9223372036854775807)      // int64 max
  show (-9223372036854775808)     // int64 min
  show (9223372036854775807 + 1)  // overflow wrap? must match
  show (0x7fffffff * 0x7fffffff)
  show (1 << 30)
  show (1 << 31)
  show (1 << 60)
  show (1 << 62)
  show (1 << 63)
  show ((1 << 62) + (1 << 62))
  // Division / modulo near boundaries.
  show (4611686018427387903 / 3)
  show (4611686018427387903 % 7)
  show (-4611686018427387904 / 2)
  // to-float and back across the boundary.
  show (1073741824.to-float)
  show (4611686018427387904.to-float.to-int)
  // Shifts that could differ in smi tagging.
  show (1073741823 >> 1)
  show (1073741824 >> 1)
  // Hashing of integers across the boundary.
  show a.hash-code
  show b.hash-code
  show c.hash-code
  // Strings and byte arrays: lengths and content.
  s := "x" * 100
  show s.size
  ba := ByteArray 100: it & 0xff
  show ba.size
  show ba[99]
  // Collections across sizes.
  m := {:}
  200.repeat: m[it] = it * it
  show m.size
  show m[150]
  set := {}
  200.repeat: set.add (it % 97)
  show set.size
  // Float bit patterns.
  show (math.PI)
  show (1.0 / 3.0)
  show float.INFINITY
  show (0.0 / 0.0)
  print "edges-done"
