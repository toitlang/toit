// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// A compute-heavy program. The VM preempts it regularly to keep the page
// responsive.

fib n/int -> int:
  if n < 2: return n
  return (fib n - 1) + (fib n - 2)

main:
  [20, 25, 30].do: | n |
    start := Time.monotonic-us
    result := fib n
    elapsed := (Time.monotonic-us - start) / 1000
    print "fib($n) = $result ($elapsed ms)"
