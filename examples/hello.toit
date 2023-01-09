// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

main:
  a/any := A
  return fib a.foo

/*
main:
  start := Time.monotonic_us
  result := fib 40
  end := Time.monotonic_us
  print "$result (took $(end - start) us)"
  return result
*/

fib n:
  if n <= 2: return n
  return (fib n - 1) + (fib n - 2)

class A:
  foo:
    return 40
