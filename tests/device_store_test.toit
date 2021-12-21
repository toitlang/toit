// Copyright (C) 2021 Toitware ApS. All rights reserved.

import expect show *
import device show FlashStore

main:
  simple_operations
  invalid_keys

simple_operations:
  store := FlashStore

  a_key := "test"

  store.set a_key 1
  expect_equals 1
    store.get a_key

  store.set a_key 2
  expect_equals 2
    store.get a_key

  store.set a_key "hej"
  expect_equals "hej"
    store.get a_key

  store.delete a_key
  expect_equals null
    store.get a_key

invalid_keys:
  store := FlashStore

  empty_key ::= ""
  expect_invalid_argument:
    store.set empty_key 1
  expect_invalid_argument:
    store.get empty_key
  expect_invalid_argument:
    store.delete empty_key

  long_key ::= "1234567890123456"
  expect_invalid_argument:
    store.set long_key 1
  expect_invalid_argument:
    store.get long_key
  expect_invalid_argument:
    store.delete long_key

  privileged_key ::= "_privileged"
  expect_invalid_argument:
    store.set privileged_key 1
  expect_invalid_argument:
    store.get privileged_key
  expect_invalid_argument:
    store.delete privileged_key


expect_invalid_argument [test]:
  e := catch: test.call
  expect_equals e "INVALID_ARGUMENT"
