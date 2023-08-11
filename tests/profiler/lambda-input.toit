// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

ITERATIONS ::= 1000

run fun/Lambda:
  return fun.call

bar:
  run::
    sum := 0
    ITERATIONS.repeat: sum += it
    expect-equals 499_500 sum

foo:
  run::
    sum := 0
    for i := 0; i < ITERATIONS * 8; i++:
      sum += i
    expect-equals 31_996_000 sum

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
  Profiler.report "Lambda Profiler Test"
  Profiler.uninstall
