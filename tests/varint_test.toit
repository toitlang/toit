// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *
import encoding.varint show *
import .maskint_test show positive_integer_tests Test


negative_integer_tests ::= [
  Test -127 10,
  Test -128 10,
  Test -129 10,
]

main:
  benchmark
  more_tests

benchmark:
  tests := []
  tests.add_all positive_integer_tests
  tests.add_all negative_integer_tests

  tests.do: | t/Test |
    b := ByteArray 10
    s := encode b 0 t.i
    expect_equals t.size s
    expect_equals (byte_size b) s
    out := decode b 0
    expect_equals t.i out

more_tests:
  ba := ByteArray 10
  expect_throw "OUT_OF_BOUNDS": encode ba 1 -1
  expect_throw "OUT_OF_BOUNDS": encode ba 1 1 << 63
  expect_throw "OUT_OF_BOUNDS": encode ba 2 1 << 56
  expect_throw "OUT_OF_BOUNDS": encode ba 3 1 << 49
  expect_throw "OUT_OF_BOUNDS": encode ba 4 1 << 42
  expect_throw "OUT_OF_BOUNDS": encode ba 5 1 << 35
  expect_throw "OUT_OF_BOUNDS": encode ba 6 1 << 28
  expect_throw "OUT_OF_BOUNDS": encode ba 7 1 << 21
  expect_throw "OUT_OF_BOUNDS": encode ba 8 1 << 14
  expect_throw "OUT_OF_BOUNDS": encode ba 9 1 << 7

  expect_equals 10 (encode ba 0 -1)
  expect_equals 10 (encode ba 0 (1 << 63))
  expect_equals 9 (encode ba 1 (1 << 63) - 1)
  expect_equals 8 (encode ba 2 (1 << 56) - 1)
  expect_equals 7 (encode ba 3 (1 << 49) - 1)
  expect_equals 6 (encode ba 4 (1 << 42) - 1)
  expect_equals 5 (encode ba 5 (1 << 35) - 1)
  expect_equals 4 (encode ba 6 (1 << 28) - 1)
  expect_equals 3 (encode ba 7 (1 << 21) - 1)
  expect_equals 2 (encode ba 8 (1 << 14) - 1)
  expect_equals 1 (encode ba 9 (1 << 7) - 1)
