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

nasty n:
  a := ByteArray n
  for i := 0; i < n; i++: a[i] = i

  result := 0
  for i := 0; i < 1_000; i++:
    for j := 0; j < 1_000; j++:
      result = sum a
  return result

sum a:
  result := 0
  x := a.size
  for i := 0; i < x; i++:
    result += a[i]
  return result
