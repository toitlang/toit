// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A compute-only workload for the trace comparison
// (verified/tools/compare_trace.toit):
// it prints only at the end, so that the trace up to the print does not
// depend on the timing of the system process.

main:
  seed := 12345
  list := []
  1500.repeat:
    seed = (seed * 1103515245 + 12345) & 0x7fff_ffff
    list.add seed % 10007
  list.sort --in-place
  sum := 0
  list.do: sum += it
  sorted := true
  for i := 1; i < list.size; i++:
    if list[i - 1] > list[i]: sorted = false
  print "$sum $sorted $list.first $list.last"
