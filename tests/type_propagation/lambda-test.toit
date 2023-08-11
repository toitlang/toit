// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test-simple
  test-arguments

test-simple:
  x := :: 42
  return x.call

test-arguments:
  (:: id it).call 42
  (:: | x y | id x; id y).call 42 "fisk"

id x:
  return x
