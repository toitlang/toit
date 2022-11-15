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
    rethrow ASSERTION_FAILED_ERROR (encode_error_ ASSERTION_FAILED_ERROR (message ? message : ""))
  exit -1

/**
Expects the given $condition to be false.

Otherwise reports an error (using the provided $message, if given) and exits the program.
*/
expect_not condition/bool --message/string?=null:
  expect (not condition) --message=message

/** Expects $actual to be equal to $expected. */
expect_equals expected actual:
  if expected != actual:
    expect false --message="Expected <$expected>, but was <$actual>"

/** Expects $actual to be $identical to $expected. */
expect_identical expected actual:
  if not identical expected actual:
    expect false --message="Expected <$expected>, but was <$actual>"

/** Expects $actual not to be equal to $unexpected. */
expect_not_equals unexpected actual:
  if unexpected == actual:
    expect false --message="Expected unequal for <$actual>"

/** Expects $actual not to be $identical to $unexpected. */
expect_not_identical unexpected actual:
  if identical unexpected actual:
    expect false --message="Expected unequal for <$actual>"

/** Expects $actual to be equal to `null`. */
expect_null actual:
  expect_equals null actual

/** Expects $actual to be not `null`. */
expect_not_null actual:
  if actual == null:
    expect false --message="Expected not null"

/**
Expects the $actual object to be structurally equal to the $expected object.
Understands operator equality and memberwise structural equality of lists and
  maps.
*/
expect_structural_equals expected/Object actual/Object:
  if not structural_equals_ expected actual:
    expect false --message="Expected <$expected>, but was <$actual>"

structural_equals_ expected actual -> bool:
  if expected is List:
    return list_equals_ expected actual
  else if expected is Map:
    return map_equals_ expected actual
  else:
    return expected == actual

/** Expects the $actual list to be equal to the $expected list. */
expect_list_equals expected/List actual/List:
  if not list_equals_ expected actual:
    expect false --message="Expected <$expected>, but was <$actual>"

list_equals_ expected/List actual -> bool:
  if actual is List and actual.size == expected.size:
    all_good := true
    for i := 0; i < expected.size; i++:
      if not structural_equals_ expected[i] actual[i]:
        all_good = false
        break
    if all_good: return true
  return false

map_equals_ expected/Map actual -> bool:
  if actual is Map and actual.size == expected.size:
    all_good := true
    expected.do: | key value |
      if not structural_equals_
          value
          actual.get key --if_absent=(: all_good = false; null):
        all_good = false
    if all_good: return true
  return false

/**
Expects the $actual byte array to be equal to the $expected byte array.
*/
expect_bytes_equal expected/ByteArray actual/ByteArray:
  if actual.size != expected.size:
    expect false --message="Expected <$expected> (size $expected.size), but was <$actual> (size $actual.size)"

  all_good := true
  for i := 0; i < expected.size; i++:
    if expected[i] != actual[i]:
      expect false --message="Expected <$expected>, but was <$actual> (differ at position $i, expected $expected[i], but was $actual[i])"

/** Expects $throw_block to throw an object equal to the $expected value. */
expect_throw expected [throw_block]:
  try:
    error := catch --trace=(: expected != it) --unwind=(: expected != it):
      throw_block.call
    if expected != error:
      expect false --message="Expected throw, got <null>"
  finally: | is_exception exception |
    if is_exception:
      expect false --message="Expected throw with <$expected>, but was <$exception.value>"
    return

/** Expects $no_throw_block to not throw. */
expect_no_throw [no_throw_block]:
  res := catch no_throw_block
  if res: expect false --message="Expected no throw, got <$res>"
