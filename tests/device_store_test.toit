// Copyright (C) 2021 Toitware ApS. All rights reserved.

import expect show *
import device show FlashStore

main:
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
