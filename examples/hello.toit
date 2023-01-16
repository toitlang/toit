// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

main:
  start := Time.monotonic_us
  result := fib 40
  end := Time.monotonic_us
  print_ "fib(40) = $result | took $(end - start) us"

fib n:
  if n <= 2: return n
  return (fib n - 1) + (fib n - 2)
