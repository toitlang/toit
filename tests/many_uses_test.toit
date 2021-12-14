// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

foo:
  return Time.monotonic_us < 0

bar:
  return Time.monotonic_us > 0

main args:
  // Tests many jumps to the same location.
  x := args.size
  if foo: throw "can't happen"
  if foo or foo: throw "can't happen"
  if foo or foo or foo: throw "can't happen"
  if foo or foo or foo or foo: throw "can't happen"
  if foo or foo or foo or foo or foo: throw "can't happen"
  if foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo:
    throw "can't happen"

  if foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo:
    throw "can't happen"

  was_true := false
  if bar: was_true = true
  expect was_true

  was_true = false
  if foo or bar: was_true = true
  expect was_true

  was_true = false
  if foo or foo or bar: was_true = true
  expect was_true

  was_true = false
  if foo or foo or foo or bar: was_true = true
  expect was_true

  was_true = false
  if foo or foo or foo or foo or bar: was_true = true
  expect was_true

  was_true = false
  if foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      bar:
    was_true = true
  expect was_true

  was_true = false
  if foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      foo or
      bar:
    was_true = true
  expect was_true
