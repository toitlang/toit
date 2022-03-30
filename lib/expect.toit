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

/** Expects the $actual list to be equal to the $expected list. */
expect_list_equals expected/List actual/List:
  if actual.size == expected.size:
    all_good := true
    for i := 0; i < expected.size; i++:
      if expected[i] != actual[i]:
        all_good = false
        break
    if all_good: return
  expect false --message="Expected <$expected>, but was <$actual>"

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
     throw_block.call
  finally: | is_exception exception |
    if not is_exception:
      expect false --message="Expected throw, got <null>"
    if expected != exception.value:
      expect false --message="Expected throw with <$expected>, but was <$exception.value>"
    return

/** Expects $no_throw_block to not throw. */
expect_no_throw [no_throw_block]:
  res := catch no_throw_block
  if res: expect false --message="Expected no throw, got <$res>"
