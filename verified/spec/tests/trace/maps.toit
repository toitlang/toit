// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A compute-only workload for the trace comparison: maps and sets.

main:
  map := {:}
  400.repeat: map["k$it"] = it * it
  set := {}
  300.repeat: set.add it * 7 % 101
  total := 0
  map.do: | k v | total += v
  200.repeat: map.remove "k$(it * 2)"
  found := 0
  400.repeat: if map.contains "k$it": found++
  print "$total $found $set.size $(map.get "k3")"
