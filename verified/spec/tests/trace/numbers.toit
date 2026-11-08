// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A compute-only workload for the trace comparison: smi, large integer and
// float arithmetic, and string building.

main:
  big := 1
  60.repeat: big = big * 3 + it
  f := 0.0
  500.repeat: f += it.to-float / 7.0
  s := ""
  80.repeat: s += "$(it % 10)"
  bits := 0
  1000.repeat: bits = (bits << 1 ^ it) & 0xffff_ffff
  print "$big $(f.to-int) $s.size $bits"
