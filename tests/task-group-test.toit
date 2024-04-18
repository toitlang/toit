// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

main:
  run-test:: test-simple
  run-test:: test-bad-arguments
  run-test:: test-required
  run-test:: test-order
  run-test:: test-eager-stop
  run-test:: test-exceptions
  run-test:: test-timeout
  run-test:: test-cancellation
  run-test:: test-fib

run-test lambda/Lambda:
  child := run-case lambda
  expect-not child.is-canceled

run-case lambda/Lambda -> Task:
  latch := monitor.Latch
  child := task::
    try:
      lambda.call
    finally:
      critical-do: latch.set null
  latch.get
  return child

test-simple:
  expect-structural-equals {:} (Task.group [])

  expect-structural-equals { 0: 42 } (Task.group [
    :: 42,
  ])

  expect-structural-equals { 0: 42, 1: 87 } (Task.group [
    :: 42,
    :: 87,
  ])

test-bad-arguments:
  expect-throw "Bad Argument": (Task.group --required=-1 [ :: 42, :: 87 ])
  expect-throw "Bad Argument": (Task.group --required= 3 [ :: 42, :: 87 ])
  expect-throw "Bad Argument": (Task.group --required= 9 [ :: 42, :: 87 ])

test-required:
  expect-structural-equals {:} (Task.group --required=0 [
    :: 42,
    :: sleep --ms=1_000; 87,
  ])
  expect-structural-equals { 0: 42 } (Task.group --required=1 [
    :: 42,
    :: sleep --ms=1_000; 87,
  ])
  expect-structural-equals { 1: 42 } (Task.group --required=1 [
    :: sleep --ms=1_000; throw "ugh",
    :: 42,
  ])
  expect-structural-equals { 0: 42, 2: 99 } (Task.group --required=2 [
    :: 42,
    :: sleep --ms=1_000; 87,
    :: sleep --ms=200; 99,
  ])

test-order:
  expect-structural-equals [0, 1] (Task.group [
    :: null,
    :: sleep --ms=200,
  ]).keys

  expect-structural-equals [1, 0] (Task.group [
    :: sleep --ms=200,
    :: null,
  ]).keys

  expect-structural-equals [1, 3, 2, 0] (Task.group [
    :: sleep --ms=600,
    :: null,
    :: sleep --ms=400,
    :: sleep --ms=200,
  ]).keys

test-eager-stop:
  expect-throw "ugh": Task.group [
    :: throw "ugh",
    :: unreachable, // Not called.
  ]

test-exceptions:
  ran := false
  expect-throw "ugh": Task.group [
    :: ran = true; 42,
    :: throw "ugh",
  ]
  expect ran

  expect-throw "OUT_OF_BOUNDS": Task.group [
    :: 42,
    :: sleep --ms=100; [0][1],
    :: 98,
  ]

test-timeout:
  expect-throw DEADLINE-EXCEEDED-ERROR:
    Task.group [
      :: with-timeout --ms=20: sleep --ms=200,
      :: sleep --ms=500,
    ]

  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=20:
      Task.group [
        :: sleep --ms=200,
        :: sleep --ms=500,
      ]

test-cancellation:
  child := run-case::
    Task.group [
      :: Task.current.cancel,
      :: sleep --ms=200,
    ]
  expect child.is-canceled

  child = run-case::
    Task.group [
      :: Task.current.cancel; sleep --ms=10,
      :: sleep --ms=200,
    ]
  expect child.is-canceled

  child = run-case::
    done := monitor.Latch
    helper := task::
      try:
        Task.group [
          :: sleep --ms=1_000,
          :: sleep --ms=2_000,
        ]
      finally:
        critical-do: done.set null
    sleep --ms=10
    helper.cancel
    with-timeout --ms=200: done.get
  expect-not child.is-canceled

test-fib:
  expect-equals 5 (fib 5)
  expect-equals 21 (fib 8)

fib n/int -> int:
  if n <= 2: return 1
  children := Task.group [
    :: fib n - 1,
    :: fib n - 2,
  ]
  return children[0] + children[1]
