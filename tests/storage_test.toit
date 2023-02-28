// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.storage
import expect show *

main:
  test_ram
  test_flash

test_ram:
  a := storage.Bucket.open --ram "bucket-a"
  b := storage.Bucket.open --ram "bucket-b"
  expect_throw "key not found": a["hest"]
  expect_throw "key not found": b["hest"]

  a["hest"] = 1234
  expect_equals 1234 a["hest"]
  expect_throw "key not found": b["hest"]

  b["hest"] = 2345
  expect_equals 1234 a["hest"]
  expect_equals 2345 b["hest"]

  alias := storage.Bucket.open "ram:bucket-a"
  expect_equals 1234 alias["hest"]
  alias.close

  non_alias := storage.Bucket.open "flash:bucket-a"
  expect_throw "key not found": non_alias["hest"]
  non_alias.close

  a.remove "hest"
  expect_throw "key not found": a["hest"]
  expect_equals 2345 b["hest"]

  b.remove "hest"
  expect_throw "key not found": a["hest"]
  expect_throw "key not found": b["hest"]

test_flash:
  bucket := storage.Bucket.open --flash "bucket"
  bucket.remove "hest"
  expect_throw "key not found": bucket["hest"]

  expect_equals 42 (bucket.get "hest" --if_absent=: 42)
  expect_equals 87 (bucket.get "hest" --init=: 87)
  expect_equals 87 bucket["hest"]

  alias := storage.Bucket.open "flash:bucket"
  expect_equals 87 alias["hest"]
  alias.close

  non_alias := storage.Bucket.open "ram:bucket"
  expect_throw "key not found": non_alias["hest"]
  non_alias.close

  bucket.remove "hest"
  expect_throw "key not found": bucket["hest"]

  expect_throw "key not found": bucket[""]
  bucket[""] = 1234
  expect_equals 1234 bucket[""]
  bucket.remove ""
  expect_throw "key not found": bucket[""]

  long := "2357" * 8
  bucket[long] = 2345
  expect_equals 2345 bucket[long]
  bucket.remove long
  expect_throw "key not found": bucket[long]
