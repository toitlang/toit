// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Tests the parser, and, in particular, different indentations.

// Test different multiline imports.
// The actual imported declarations don't matter and can be changed.
import bytes
  as bytes2

import bytes show
  Buffer
  BufferConsumer

import bytes show Buffer
  BufferConsumer

// Test exporting on multiple lines.
export
  Buffer
  BufferConsumer

export BufferConsumer
  BufferConsumer

run [b]:
  return b.call

test_different_indentations:
  // Indentations can be more than 2 (as long as they are consistent at the same
  // level).
  x := run:
    if true:
        "good"
        "still good"
  expect_equals "still good" x

  x = run:
    if true:
     "good"
     "still good"
  expect_equals "still good" x

  x = run:
    if true:
      "good"
        else:  // Else can be at any level. Does not require the next line to be indented more.
      "bad"
  expect_equals "good" x

  x = run:
    if false:
      "bad"
        else if true:
          // Else if, however, start a new "indentation".
          "must be indented"
  expect_equals "must be indented" x

  x = run:
    for i := 0; i < 1; i++:
      t := foo (if true: 499 else: break):
        it + 1
      expect_equals 500 t
  expect_null x

  x = run:
    for i := 0; i < 1; i++:
      t := foo
        if true: 499 else: break
        : it + 1
      expect_equals 500 t

  expect_null x

  x = run:
    if true: if false: "bad"
    else: "bad"
  expect_equals null x

  x = run:
    if true: if false: "bad"
      else: "good"
  expect_equals "good" x

  x = run:
    if true: if false: "bad" else: "good"
  expect_equals "good" x

foo x:
  return x

foo x y:
  return x

foo x [y]:
  return y.call x

foo x y z:
  return x

test_if:
  // Empty blocks are ok
  x := run:
    if true:
    else:
    "good"
  expect_equals "good" x

  x = run:
    if foo
            true   // This indentation has no impact on the then-body.
            1
            2:
      "good"
    else:
      "bad"
  expect_equals "good" x

  x = run:
    if foo
            true   // This indentation has no impact on the then-body.
            1
            2
    :  // The ':' can be at the level of the construct.
      "good"
    else:
      "bad"
  expect_equals "good" x

  // This used to crash the old parser.
  x = if true: if false: "bad"
    else: "good"
  expect_equals "good" x

  x = run:
    if true
         and true:
      "good"
    else:
      "bad"
  expect_equals "good" x

  x = run:
    if true and
         true:
      "good"
    else:
      "bad"
  expect_equals "good" x

test_loops:
  x := run:
    for i := 0
    ; i < 1
    ; i++
    : "good"
  expect_null x

test_conditional:
  // The else branch of the conditional may contain colons.
  x := false ? false : run: "good"
  expect_equals "good" x

  // The else branch of the conditional may contain colons.
  x = if false ? false : true:
    "good"
  expect_equals "good" x

test_operators:
  x := 4 *
    3 + 1
  expect_equals 16 x

  x = 4
    * 3 + 1
  expect_equals 13 x

multi [b1] [b2]:
  return b1.call + b2.call

multi l1 l2:
  return l1.call + l2.call

test_blocks_lambdas:
  x := multi
    : 499
    : 1
  expect_equals 500 x

  x = multi
    :: 499
    :: 1
  expect_equals 500 x

test_try:
  x := run:
    result := 0
    try: try:
      finally: result++
    finally: result++
    result
  expect_equals 2 x

  x = run:
    result := 0
    try: try: finally: result++ finally: result++
    result
  expect_equals 2 x

main:
  test_different_indentations
  test_if
  test_loops
  test_conditional
  test_operators
  test_blocks_lambdas
  test_try
