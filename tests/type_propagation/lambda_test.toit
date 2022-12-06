// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_simple
  test_arguments

test_simple:
  x := :: 42
  return x.call

test_arguments:
  (:: id it).call 42
  (:: | x y | id x; id y).call 42 "fisk"

id x:
  return x
