// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

ITERATIONS ::= 1000

bar:
  sum := 0
  ITERATIONS.repeat: sum += it
  expect_equals 499500 sum

foo:
  sum := 0
  for i := 0; i < ITERATIONS; i++:
    sum += i
  expect_equals 499500 sum

  bar

main:
  Profiler.install false
  Profiler.do: foo
  Profiler.report "Profiler Test"
  Profiler.uninstall
