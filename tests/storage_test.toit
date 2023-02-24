// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.storage
import expect show *

main:
  test_bucket_ram
  test_bucket_flash
  test_region_flash

test_bucket_ram:
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

test_bucket_flash:
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

test_region_flash:
  region := storage.Region.open --flash "first-region" --size=1000
  expect_equals 4096 region.sector_size
  expect_equals 0xff region.erase_byte
  expect ((region.read --from=0 --to=region.size).every: it == region.erase_byte)

  snippets := []
  written := 0
  while written < region.size:
    snippet_size := min (random 128) (region.size - written)
    snippets.add (ByteArray snippet_size: random 0x100)
    region.write --from=written snippets.last
    written += snippet_size

  read := 0
  snippets.do: | snippet/ByteArray |
    expect_bytes_equal snippet (region.read --from=read --to=read + snippet.size)
    read += snippet.size
