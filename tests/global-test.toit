// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

FOO := 42
BAR := 99
BAZ := List 2

exec [block]: return block.call

cyclic := foo-cyclic
foo-cyclic: return cyclic

multi-attempt := try-multi-init
multi-init-counter := 0
try-multi-init:
  if multi-init-counter++ < 3: throw "not yet"
  return 42

main:
  expect-equals 42 FOO
  expect-equals 87 (exec: FOO = 87)
  expect-equals 87 FOO

  expect-equals 99 BAR
  expect-equals 123 (exec: BAR = 123)
  expect-equals 123 BAR
  expect-equals 87 FOO

  BAZ[0] = 3
  BAZ[1] = 7
  expect-equals (7 - 3) (BAZ[1] - BAZ[0])

  expect-throw "INITIALIZATION_IN_PROGRESS": cyclic

  expect-throw "not yet": multi-attempt
  expect-throw "not yet": multi-attempt
  expect-throw "not yet": multi-attempt
  expect-equals 42 multi-attempt
