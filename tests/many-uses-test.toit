// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo:
  return Time.monotonic-us < 0

bar:
  return Time.monotonic-us > 0

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

  was-true := false
  if bar: was-true = true
  expect was-true

  was-true = false
  if foo or bar: was-true = true
  expect was-true

  was-true = false
  if foo or foo or bar: was-true = true
  expect was-true

  was-true = false
  if foo or foo or foo or bar: was-true = true
  expect was-true

  was-true = false
  if foo or foo or foo or foo or bar: was-true = true
  expect was-true

  was-true = false
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
    was-true = true
  expect was-true

  was-true = false
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
    was-true = true
  expect was-true
