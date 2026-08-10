// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .test

PARALLEL-TASKS ::= 40
SLEEPS-PER-TASK ::= 20
PARALLEL-LATENCY-LIMIT-US ::= 10_000
MAX-PARALLEL-WORKERS-ABOVE-LIMIT ::= PARALLEL-TASKS / 10

main:
  run-test: test

test:
  test-single
  test-parallel

test-single:
  // Warm up the reusable native timer so its one-time allocation is not part
  // of the latency measurement.
  sleep --ms=1

  minimum-us := 1 << 60
  25.repeat:
    before := Time.monotonic-us
    sleep --ms=2
    elapsed-us := Time.monotonic-us - before
    expect elapsed-us >= 2_000
    minimum-us = min minimum-us elapsed-us

  // The 100Hz FreeRTOS tick used to make every short asynchronous sleep take
  // at least one 10ms tick. Allow ample scheduling jitter, but require at least
  // one sample that clearly did not wait for such a tick.
  expect minimum-us < 6_000

test-parallel:
  workers := List PARALLEL-TASKS: |index/int|
    :: run-sleeper index
  results := Task.group workers
  expect-equals PARALLEL-TASKS results.size
  low-latency-workers := 0
  results.values.do: |minimum-us/int|
    if minimum-us < PARALLEL-LATENCY-LIMIT-US: low-latency-workers++
  // Under load, this also measures the time it takes the scheduler to run a
  // woken task. Use the old 10ms tick as the limit rather than requiring the
  // same absolute latency from sleeps whose requested durations vary from 1
  // to 5ms. Allow a small scheduler tail, but require 90% of the workers to
  // beat the old tick.
  message := "Only $low-latency-workers/$PARALLEL-TASKS workers slept for less than "
  message += "$(PARALLEL-LATENCY-LIMIT-US)us: $(results.values)"
  expect low-latency-workers >= PARALLEL-TASKS - MAX-PARALLEL-WORKERS-ABOVE-LIMIT
      --message=message

run-sleeper index/int -> int:
  requested-ms := 1 + index % 5
  minimum-us := 1 << 60
  SLEEPS-PER-TASK.repeat:
    before := Time.monotonic-us
    sleep --ms=requested-ms
    elapsed-us := Time.monotonic-us - before
    expect elapsed-us >= requested-ms * 1_000
    minimum-us = min minimum-us elapsed-us
  return minimum-us
