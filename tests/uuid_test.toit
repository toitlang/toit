// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import uuid as UUID

expect_throws name [code]:
  expect_equals
    name
    catch code

main:
  test_parse
  test_uuid5
  test_equality
  test_hash_code

test_equality:
  u0 := UUID.parse "9c20dadc1abe5520b92c85b948daf44a"
  u1 := UUID.parse "9c-20-da-dc-1a-be-55-20-b9-2c-85-b9-48-da-f4-4a"
  expect_equals u0 u0
  expect_equals u0 u1
  expect_equals u1 u0

  u2 := UUID.parse "8c-20-da-dc-1a-be-55-20-b9-2c-85-b9-48-da-f4-4a"
  u3 := UUID.parse "9c-20-da-dc-1a-be-55-21-b9-2c-85-b9-48-da-f4-4a"
  u4 := UUID.parse "9c-20-da-dc-1a-be-55-21-b9-2c-85-b9-48-da-f4-4b"
  expect (not u0 == u2)
  expect (not u0 == u3)
  expect (not u0 == u4)
  expect (not u2 == u0)
  expect (not u3 == u0)
  expect (not u4 == u0)

test_hash_code:
  u0 := UUID.parse "9c20dadc1abe5520b92c85b948daf44a"
  u1 := UUID.parse "ee9554d1-1db3-5e8f-bbf6-1b2bdce05788"
  u2 := UUID.parse "0228e0ad-cb4a-4708-a308-0633ed94b104"
  u3 := UUID.parse "123e4567-e89b-12d3-a456-426655440000"
  u4 := UUID.parse "9c-20-da-dc-1a-be-55-20-b9-2c-85-b9-48-da-f4-4a" // == u0
  uuids := {u0, u1, u2, u3, u4}
  expect_equals 4 uuids.size

  // We expect the distinct, random UUIDs to have distinct hash codes.
  hash_codes := uuids.map: it.hash_code
  expect_equals 4 hash_codes.size

test_parse:
  expect_equals
    "9c20dadc-1abe-5520-b92c-85b948daf44a"
    (UUID.parse "9c20dadc-1abe-5520-b92c-85b948daf44a").stringify
  expect_equals
    "9c20dadc-1abe-5520-b92c-85b948daf44a"
    (UUID.parse "9c20dadc1abe5520b92c85b948daf44a").stringify
  expect_equals
    "9c20dadc-1abe-5520-b92c-85b948daf44a"
    (UUID.parse "9c-20-da-dc-1a-be-55-20-b9-2c-85-b9-48-da-f4-4a").stringify

  expect_throws "INVALID_UUID":  UUID.parse ""
  expect_throws "OUT_OF_BOUNDS": UUID.parse "9c20dadc-1abe-5520-b92c-85b948daf44"
  expect_throws "INVALID_UUID":  UUID.parse "9c20dadc-1abe-5520-b92c-85b948daf44aa"

test_uuid5:
  ns := UUID.parse "9c20dadc-1abe-5520-b92c-85b948daf44a"
  data := ByteArray 100: it

  uuid := UUID.uuid5 ns data
  expect_equals
    "ee9554d1-1db3-5e8f-9bf6-1b2bdce05788"
    "$uuid"
