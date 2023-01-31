// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

main:
  run_test:: test_simple
  run_test:: test_bad_arguments
  run_test:: test_required
  run_test:: test_order
  run_test:: test_eager_stop
  run_test:: test_exceptions
  run_test:: test_timeout
  run_test:: test_cancellation
  run_test:: test_fib

run_test lambda/Lambda:
  child := run_case lambda
  expect_not child.is_canceled

run_case lambda/Lambda -> Task:
  latch := monitor.Latch
  child := task::
    try:
      lambda.call
    finally:
      critical_do: latch.set null
  latch.get
  return child

test_simple:
  expect_structural_equals { 0: 42, 1: 87 } (Task.group [
    :: 42,
    :: 87,
  ])

test_bad_arguments:
  expect_throw "Bad Argument": (Task.group [])
  expect_throw "Bad Argument": (Task.group [ :: 42 ])
  expect_throw "Bad Argument": (Task.group --required=-1 [ :: 42, :: 87 ])
  expect_throw "Bad Argument": (Task.group --required= 0 [ :: 42, :: 87 ])
  expect_throw "Bad Argument": (Task.group --required= 3 [ :: 42, :: 87 ])
  expect_throw "Bad Argument": (Task.group --required= 9 [ :: 42, :: 87 ])

test_required:
  expect_structural_equals { 0: 42 } (Task.group --required=1 [
    :: 42,
    :: sleep --ms=1_000; 87,
  ])
  expect_structural_equals { 1: 42 } (Task.group --required=1 [
    :: sleep --ms=1_000; throw "ugh",
    :: 42,
  ])
  expect_structural_equals { 0: 42, 2: 99 } (Task.group --required=2 [
    :: 42,
    :: sleep --ms=1_000; 87,
    :: sleep --ms=200; 99,
  ])

test_order:
  expect_structural_equals [0, 1] (Task.group [
    :: null,
    :: sleep --ms=200,
  ]).keys

  expect_structural_equals [1, 0] (Task.group [
    :: sleep --ms=200,
    :: null,
  ]).keys

  expect_structural_equals [1, 3, 2, 0] (Task.group [
    :: sleep --ms=600,
    :: null,
    :: sleep --ms=400,
    :: sleep --ms=200,
  ]).keys

test_eager_stop:
  expect_throw "ugh": Task.group [
    :: throw "ugh",
    :: unreachable, // Not called.
  ]

test_exceptions:
  ran := false
  expect_throw "ugh": Task.group [
    :: ran = true; 42,
    :: throw "ugh",
  ]
  expect ran

  expect_throw "OUT_OF_BOUNDS": Task.group [
    :: 42,
    :: sleep --ms=100; [0][1],
    :: 98,
  ]

test_timeout:
  expect_throw DEADLINE_EXCEEDED_ERROR:
    Task.group [
      :: with_timeout --ms=20: sleep --ms=200,
      :: sleep --ms=500,
    ]

  expect_throw DEADLINE_EXCEEDED_ERROR:
    with_timeout --ms=20:
      Task.group [
        :: sleep --ms=200,
        :: sleep --ms=500,
      ]

test_cancellation:
  child := run_case::
    Task.group [
      :: Task.current.cancel,
      :: sleep --ms=200,
    ]
  expect child.is_canceled

  child = run_case::
    Task.group [
      :: Task.current.cancel; sleep --ms=10,
      :: sleep --ms=200,
    ]
  expect child.is_canceled

  child = run_case::
    done := monitor.Latch
    helper := task::
      try:
        Task.group [
          :: sleep --ms=1_000,
          :: sleep --ms=2_000,
        ]
      finally:
        critical_do: done.set null
    sleep --ms=10
    helper.cancel
    with_timeout --ms=200: done.get
  expect_not child.is_canceled

test_fib:
  expect_equals 5 (fib 5)
  expect_equals 21 (fib 8)

fib n/int -> int:
  if n <= 2: return 1
  children := Task.group [
    :: fib n - 1,
    :: fib n - 2,
  ]
  return children[0] + children[1]
