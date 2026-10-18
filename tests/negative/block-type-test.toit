// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

filter [predicate int -> bool] -> none:
  predicate.call "x"
  predicate.call 1 2
  predicate.call
  x/string := predicate.call 1

pass-through [b string -> bool] -> none:
  filter b

returns-none [b -> none] -> none:
  x := b.call

no-params [b -> any] -> any:
  return b.call

non-nullable [b int -> int] -> int:
  return b.call null

alias [b int -> bool] -> bool:
  c := b
  c.call "x"
  return c.call 1 2

nullable-return [b -> int?] -> int?:
  return b.call

yields-none -> none:
  // The block completes without a value.
  filter: print it

main:
  filter: |x/string| true
  filter: |x y| true
  filter: |x/int| 42
  filter: "str"
  b := : |x/string| true
  filter b
  c := : |x/int| true
  c.call "x"
  c.call
  no-params: |x| x               // Error: the block is called without arguments.
  no-params: it                  // Error: `it` is a parameter too.
  nullable-return: print "x"     // OK: yields null.
  nullable-return: "x"           // Error.
  filter:                        // Error: the loop can exit, so the block yields null.
    while true: break
  // OK: fewer parameters, compatible types.
  filter: true
  filter: |x/any| true
  filter: |x| x == 1
  filter: it == 1
