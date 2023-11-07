// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Utilities for expressing expectations in tests.
*/

/** Expects the given $condition to evaluate to true. */
expect [condition]:
  expect condition.call

/**
Expects the given $condition to be true.

Otherwise reports an error (using the provided $message, if given) and exits the program.
*/
expect condition/bool --message/string?=null:
  if condition: return
  print (message ? ": $message" : ".")
  catch --trace:
    rethrow ASSERTION-FAILED-ERROR (encode-error_ ASSERTION-FAILED-ERROR (message ? message : ""))
  exit -1

/**
Expects the given $condition to be false.

Otherwise reports an error (using the provided $message, if given) and exits the program.
*/
expect-not condition/bool --message/string?=null:
  expect (not condition) --message=message

/** Expects $actual to be equal to $expected. */
expect-equals expected actual:
  if expected != actual:
    expect false --message="Expected <$expected>, but was <$actual>"

/** Expects $actual to be $identical to $expected. */
expect-identical expected actual:
  if not identical expected actual:
    expect false --message="Expected <$expected>, but was <$actual>"

/** Expects $actual not to be equal to $unexpected. */
expect-not-equals unexpected actual:
  if unexpected == actual:
    expect false --message="Expected unequal for <$actual>"

/** Expects $actual not to be $identical to $unexpected. */
expect-not-identical unexpected actual:
  if identical unexpected actual:
    expect false --message="Expected unequal for <$actual>"

/** Expects $actual to be equal to `null`. */
expect-null actual:
  expect-equals null actual

/** Expects $actual to be not `null`. */
expect-not-null actual:
  if actual == null:
    expect false --message="Expected not null"

/**
Expects the $actual object to be structurally equal to the $expected object.
Understands operator equality and memberwise structural equality of lists and
  maps.
*/
expect-structural-equals expected/Object actual/Object:
  if not structural-equals_ expected actual:
    expect false --message="Expected <$expected>, but was <$actual>"

structural-equals_ expected actual -> bool:
  if expected is List:
    return list-equals_ expected actual
  else if expected is Map:
    return map-equals_ expected actual
  else:
    return expected == actual

/** Expects the $actual list to be equal to the $expected list. */
expect-list-equals expected/List actual/List:
  if not list-equals_ expected actual:
    expect false --message="Expected <$expected>, but was <$actual>"

list-equals_ expected/List actual -> bool:
  if actual is List and actual.size == expected.size:
    all-good := true
    for i := 0; i < expected.size; i++:
      if not structural-equals_ expected[i] actual[i]:
        all-good = false
        break
    if all-good: return true
  return false

map-equals_ expected/Map actual -> bool:
  if actual is Map and actual.size == expected.size:
    all-good := true
    expected.do: | key value |
      if not structural-equals_
          value
          actual.get key --if-absent=(: all-good = false; null):
        all-good = false
    if all-good: return true
  return false

/**
Expects the $actual byte array to be equal to the $expected byte array.
*/
expect-bytes-equal expected/ByteArray actual/ByteArray:
  if actual.size != expected.size:
    expect false --message="Expected <$expected> (size $expected.size), but was <$actual> (size $actual.size)"

  all-good := true
  for i := 0; i < expected.size; i++:
    if expected[i] != actual[i]:
      expect false --message="Expected <$expected>, but was <$actual> (differ at position $i, expected $expected[i], but was $actual[i])"

/** Expects $throw-block to throw an object equal to the $expected value. */
expect-throw expected [throw-block]:
  actual/any := null
  try:
    actual = throw-block.call
  finally: | is-exception exception |
    if not is-exception:
      expect false --message="Expected throw, got <$actual>"
    if expected != exception.value:
      expect false --message="Expected throw with <$expected>, but was <$exception.value>"
    return

/** Expects $no-throw-block to not throw. */
expect-no-throw [no-throw-block]:
  res := catch no-throw-block
  if res: expect false --message="Expected no throw, got <$res>"
