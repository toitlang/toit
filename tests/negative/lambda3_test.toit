// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  foo x / string:
    if x is not string: throw "not string"

run f:
  f.call

main:
  a := A
  a.foo 5
  run:: a.foo 3

  a2 := A
  if Time.now.utc.m >= 0: a2 = A  // Mutated.

  run::
    a2.foo 499

  unresolved
