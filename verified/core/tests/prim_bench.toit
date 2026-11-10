// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Primitive-heavy microbenchmarks for the Rust primitives
(verified/core/src/prims). Run untrusted (format 2) with and without
TOIT_V2_RUST_PRIMITIVES=1; prints the best of 5 runs per benchmark in ms.
*/

bench name/string [block] -> none:
  best := -1
  5.repeat:
    start := Time.monotonic-us
    block.call
    t := Time.monotonic-us - start
    if best < 0 or t < best: best = t
  print "$name: $(%.2f best / 1000.0) ms"

main:
  bench "map-string-keys":
    m := {:}
    2000.repeat: m["key-$it"] = it
    sum := 0
    20.repeat:
      2000.repeat: sum += m["key-$it"]
    if sum == 0: throw "x"
  bench "string-concat-slice":
    s := ""
    3000.repeat: s = (s + "ab")[0..min s.size 200] + "x"
    if s.size == 0: throw "x"
  bench "list-add":
    5.repeat:
      l := []
      20000.repeat: l.add it
  bench "byte-array":
    b := ByteArray 4096
    20.repeat: | r |
      b.size.repeat: b[it] = it + r
      sum := 0
      b.size.repeat: sum += b[it]
    c := ByteArray 4096
    200.repeat: c.replace 0 b 0 4096
  bench "large-int":
    x := 0x1234_5678_9abc_def0
    sum := 0
    50000.repeat: sum = (sum + x * it) ^ (x >> 3)
  bench "float":
    f := 0.0
    50000.repeat: f = f * 0.999 + it.to-float / 3.0
  bench "string-compare-hash":
    strs := List 500: "string number $it"
    sum := 0
    20.repeat:
      strs.do: sum += it.hash-code
      sorted := strs.sort: | a b | a.compare-to b
  bench "smi-overflow":
    sum := 0
    100000.repeat: sum += (it * 1000003) % 97
