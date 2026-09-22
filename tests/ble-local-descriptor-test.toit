// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system
import ble.experimental.attribute-server as attributes
import .ble-attribute-security-test as security

main:
  basic-descriptors
  writable-description
  description-capacity

basic-descriptors:
  database := attributes.Database
  expect-throw "INVALID_ARGUMENT": database.add-descriptor 0 #[1, 0x29]
  database.add-service #[0xf0, 0xff]
  value := database.add-characteristic #[0xf1, 0xff] --read --notify
  expect-equals 3 value
  [#[0, 0x28], #[3, 0x28], #[0, 0x29], #[2, 0x29], #[3, 0x29],
    #[0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0, 2, 0x29, 0, 0]].do: | uuid/ByteArray |
    expect-throw "GATT_RESERVED_DESCRIPTOR": database.add-descriptor value uuid
  expect-throw "INVALID_ARGUMENT": database.add-descriptor value #[1, 0x29] --value=(ByteArray 21)
  description := database.add-descriptor value #[1, 0x29] --value=#[65]
  // Core Vol 3 Part G 3.3.3.2 allows one User Description per characteristic.
  description-128 := #[0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0, 1, 0x29, 0, 0]
  [#[1, 0x29], description-128].do: | uuid/ByteArray |
    expect-throw "GATT_DUPLICATE_DESCRIPTOR":
      database.add-descriptor value uuid --value=#[66]
  vendor := database.add-descriptor value #[0xf2, 0xff] --write --authenticated --value=#[7]
  expect-equals 5 description
  expect-equals 6 vendor
  next := database.add-characteristic #[0xf3, 0xff] --read
  expect-equals 8 next
  expect-equals 9 (database.add-descriptor next description-128 --value=#[67])
  expect-throw "GATT_DUPLICATE_DESCRIPTOR": database.add-descriptor next #[1, 0x29]
  expect-throw "INVALID_ARGUMENT": database.add-descriptor value #[0xf4, 0xff]
  database.add-service #[0xf5, 0xff]
  expect-throw "INVALID_ARGUMENT": database.add-descriptor next #[0xf4, 0xff]
  evidence := security.Evidence
  session := database.session --security=evidence
  try:
    expect-throw "GATT_DATABASE_SEALED": database.add-descriptor next #[0xf4, 0xff]
    expect-equals #[5, 1, 4, 0, 2, 0x29, 5, 0, 1, 0x29, 6, 0, 0xf2, 0xff]
        session.request #[4, 4, 0, 6, 0]
    expect-equals #[0x0b, 65] (session.request #[0x0a, 5, 0])
    expect-equals #[1, 0x12, 5, 0, 3] (session.request #[0x12, 5, 0, 99])
    expect-equals #[1, 0x0a, 6, 0, 5] (session.request #[0x0a, 6, 0])
    evidence.paired = true
    evidence.encrypted = true
    expect-equals #[1, 0x12, 6, 0, 5] (session.request #[0x12, 6, 0, 42])
    evidence.authenticated = true
    expect-equals #[0x13] (session.request #[0x12, 6, 0, 42])
    count := 0
    session.writes-do: | handle/int bytes/ByteArray |
      count++
      expect-equals vendor handle
      expect-equals #[42] bytes
      bytes.fill 0
    expect-equals 1 count
    expect-equals #[42] (database.value vendor)
    expect-equals #[0x0b, 42] (session.request #[0x0a, 6, 0])
  finally:
    session.close

writable-description:
  database := attributes.Database --value-limit=64
  database.add-service #[0xf0, 0xff]
  value := database.add-characteristic #[0xf1, 0xff] --read --notify
  vendor := database.add-descriptor value #[0xf2, 0xff] --write --value=#[7]
  expect-throw "INVALID_ARGUMENT": database.add-descriptor value #[1, 0x29] --write --value=#[0xc0, 0xaf]
  description := database.add-descriptor value
      #[0xfb, 0x34, 0x9b, 0x5f, 0x80, 0, 0, 0x80, 0, 0x10, 0, 0, 1, 0x29, 0, 0]
      --write
      --authenticated
      --value=#[65]
  expect-equals 5 vendor
  expect-equals 7 description
  expect-throw "GATT_DUPLICATE_DESCRIPTOR": database.add-descriptor value #[1, 0x29] --write
  expect-throw "GATT_INVALID_VALUE_HANDLE": database.set-value 6 #[0, 0]
  expect-throw "INVALID_ARGUMENT": database.set-value description #[0xed, 0xa0, 0x80]
  expect-equals 9 (database.add-characteristic #[0xf3, 0xff] --read)
  evidence := security.Evidence
  session := database.session --security=evidence
  try:
    expect-equals #[9, 7, 2, 0, 0x92, 3, 0, 0xf1, 0xff]
        session.request #[8, 2, 0, 2, 0, 3, 0x28]
    expect-equals #[9, 7, 8, 0, 2, 9, 0, 0xf3, 0xff]
        session.request #[8, 8, 0, 8, 0, 3, 0x28]
    expect-equals #[5, 1, 6, 0, 0, 0x29, 7, 0, 1, 0x29]
        session.request #[4, 6, 0, 7, 0]
    // Metadata is readable without authentication, but never writable.
    expect-equals #[0x0b, 2, 0] (session.request #[0x0a, 6, 0])
    expect-equals #[1, 0x12, 6, 0, 3] (session.request #[0x12, 6, 0, 0, 0])
    expect-equals #[1, 0x16, 6, 0, 3] (session.request #[0x16, 6, 0, 0, 0, 0, 0])
    expect-equals #[1, 0x0a, 7, 0, 5] (session.request #[0x0a, 7, 0])
    evidence.paired = true
    evidence.encrypted = true
    expect-equals #[1, 0x12, 7, 0, 5] (session.request #[0x12, 7, 0, 66])
    evidence.authenticated = true
    expect-equals #[0x13] (session.request #[0x12, 7, 0, 0xc3, 0xa6])
    retained := []
    session.writes-do: | handle/int bytes/ByteArray |
      expect-equals description handle
      retained.add bytes
    // Truncated, overlong, surrogate and out-of-range encodings must not commit.
    [#[0xc3], #[0xc0, 0xaf], #[0xed, 0xa0, 0x80], #[0xf4, 0x90, 0x80, 0x80]].do: | bytes/ByteArray |
      expect-equals #[1, 0x12, 7, 0, 0x13] (session.request (#[0x12, 7, 0] + bytes))
      session.writes-do: unreachable
    expect-equals #[0xc3, 0xa6] (database.value description)
    // A code point may cross Prepare Write boundaries; validate the final value.
    expect-equals #[0x17, 7, 0, 0, 0, 0xe2] (session.request #[0x16, 7, 0, 0, 0, 0xe2])
    expect-equals #[0x17, 7, 0, 1, 0, 0x82, 0xac] (session.request #[0x16, 7, 0, 1, 0, 0x82, 0xac])
    expect-equals #[0x19] (session.request #[0x18, 1])
    session.writes-do: | handle/int bytes/ByteArray |
      expect-equals description handle
      retained.add bytes
    system.process-stats --gc
    expect-equals [#[0xc3, 0xa6], #[0xe2, 0x82, 0xac]] retained
    // A malformed final description rejects all handles in the transaction.
    expect-equals #[0x17, 5, 0, 0, 0, 99] (session.request #[0x16, 5, 0, 0, 0, 99])
    expect-equals #[0x17, 7, 0, 0, 0, 0xe2] (session.request #[0x16, 7, 0, 0, 0, 0xe2])
    expect-equals #[1, 0x18, 7, 0, 0x13] (session.request #[0x18, 1])
    expect-equals #[7] (database.value vendor)
    expect-equals #[0xe2, 0x82, 0xac] (database.value description)
    session.writes-do: unreachable
    expect-equals #[0x13] (session.request #[0x12, 7, 0])
    expect-equals #[0x0b] (session.request #[0x0a, 7, 0])
  finally:
    session.close

description-capacity:
  database := attributes.Database
  database.add-service #[0xf0, 0xff]
  value := database.add-characteristic #[0xf1, 0xff] --read
  60.repeat: database.add-descriptor value #[0xf2, 0xff]
  expect-throw "GATT_DATABASE_FULL": database.add-descriptor value #[1, 0x29] --write
  // Rejection must neither consume the last slot nor change the declaration.
  expect-equals 64 (database.add-descriptor value #[1, 0x29] --value=#[65])
  session := database.session
  try:
    expect-equals #[9, 7, 2, 0, 2, 3, 0, 0xf1, 0xff]
        session.request #[8, 2, 0, 2, 0, 3, 0x28]
    expect-equals #[5, 1, 64, 0, 1, 0x29] (session.request #[4, 64, 0, 64, 0])
  finally:
    session.close
