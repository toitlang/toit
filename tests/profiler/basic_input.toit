// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

ITERATIONS ::= 1000

bar:
  sum := 0
  ITERATIONS.repeat: sum += it
  expect_equals 499500 sum

foo:
  sum := 0
  for i := 0; i < ITERATIONS * 4; i++:
    sum += i
  expect_equals 7998000 sum

compute:
  // Repeat the two computations to even
  // out performance interferences from
  // other things that run in parallel.
  10.repeat:
    foo
    bar

main:
  Profiler.install false
  Profiler.do: 1_000.repeat: compute
  Profiler.report "Profiler Test"
  Profiler.uninstall
