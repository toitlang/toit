// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

run [block]:
  return block.call

ITERATIONS ::= 5
main:
  funs := []
  for x := 0;
      (run:
        funs.add:: x
        x) < ITERATIONS
      ;
      x++:
    true
  expect_equals (ITERATIONS + 1) funs.size
  funs.size.repeat:
    expect_equals it funs[it].call

  funs = []
  for x := 0; x < ITERATIONS; (run:
      funs.add:: x
      x++):
    true
  expect_equals ITERATIONS funs.size
  funs.size.repeat:
    expect_equals (it + 1) funs[it].call

  funs = []
  for x := 0; x < ITERATIONS; (run: (funs.add:: x)):
    x++

  for i := 0; i < ITERATIONS - 1; i++:
    // The 'x' that is captured in the update, corresponds to the
    // one of the *next* iteration. The first time we enter the
    // update clause, 'x' is already equal to 'x' (because of the increment
    // in the body).
    // The same x is then incremented again in the body, making the captured
    // x being equal to '2'.
    // In the last iteration, we update enter with x equal to 5, but we don't
    // enter the body anymore, making the last two functions capture the same value.
    expect_equals (i + 2) funs[i].call
  expect_equals ITERATIONS funs[ITERATIONS - 1].call

  funs = []
  for x := 0; x++ < ITERATIONS; (run: (funs.add:: x)):
    x

  for i := 0; i < ITERATIONS; i++:
    // The 'x' that is captured in the update, corresponds to the
    // one of the *next* iteration. The first time we get into the
    // update clause, x is equal to 1, which is then immediately
    // incremented in the condition-clause.
    expect_equals (i + 2) funs[i].call
