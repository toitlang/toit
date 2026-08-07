// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .test

PARALLEL-TASKS ::= 40
SLEEPS-PER-TASK ::= 20

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
    if minimum-us < 6_000: low-latency-workers++
  // The 10ms FreeRTOS tick would keep every worker above this limit. Allow
  // some workers to suffer scheduling jitter while requiring concurrent
  // short sleeps to consistently avoid tick quantization.
  expect low-latency-workers >= PARALLEL-TASKS * 3 / 4

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
