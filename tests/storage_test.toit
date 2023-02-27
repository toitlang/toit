// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.storage
import expect show *

main:
  test_bucket_ram
  test_bucket_flash

  test_region_flash_double_open
  test_region_flash_erase
  test_region_flash_is_erased
  test_region_flash_write_all
  test_region_flash_ignore_set
  test_region_flash_invalid_arguments

  test_region_flash_delete
  test_region_flash_list

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

test_region_flash_double_open:
  region := storage.Region.open --flash "region-0" --minimum_size=1000
  expect_throw "ALREADY_IN_USE": storage.Region.open --flash "region-0" --minimum_size=1000
  region.close
  storage.Region.delete --flash "region-0"

test_region_flash_erase:
  region := storage.Region.open --flash "region-0" --minimum_size=8000
  expect_equals 8192 region.size
  expect_equals 4096 region.erase_granularity
  expect_equals 0xff region.erase_value
  region.is_erased
  expect region.is_erased
  expect ((region.read --from=0 --to=region.size).every: it == region.erase_value)

  expect_throw "Bad Argument": region.erase --from=1
  expect_throw "Bad Argument": region.erase --to=9
  expect_throw "OUT_OF_BOUNDS": region.erase --from=0 --to=0
  expect_throw "OUT_OF_BOUNDS": region.erase --from=-4096
  expect_throw "OUT_OF_BOUNDS": region.erase --to=-4096
  expect_throw "OUT_OF_BOUNDS": region.erase --from=4096 --to=0x7fff_f000
  expect_throw "OUT_OF_BOUNDS": region.erase --from=4096 --to=0
  region.close

test_region_flash_is_erased:
  region := storage.Region.open --flash "region-1" --minimum_size=1000
  region.erase
  expect region.is_erased

  expect (region.is_erased --from=1 --to=31)
  expect (region.is_erased --from=4 --to=31)
  expect (region.is_erased --from=1 --to=28)
  expect (region.is_erased --from=4 --to=28)

  region.write --from=3 #[1]
  expect_not (region.is_erased --from=1 --to=31)
  expect (region.is_erased --from=4 --to=31)
  expect_not (region.is_erased --from=1 --to=28)
  expect (region.is_erased --from=4 --to=28)

  region.write --from=29 #[2]
  expect_not (region.is_erased --from=1 --to=31)
  expect_not (region.is_erased --from=4 --to=31)
  expect_not (region.is_erased --from=1 --to=28)
  expect (region.is_erased --from=4 --to=28)

  region.write --from=17 #[2]
  expect_not (region.is_erased --from=1 --to=31)
  expect_not (region.is_erased --from=4 --to=31)
  expect_not (region.is_erased --from=1 --to=28)
  expect_not (region.is_erased --from=4 --to=28)

  expect_throw "OUT_OF_BOUNDS": region.is_erased --from=0 --to=0
  expect_throw "OUT_OF_BOUNDS": region.is_erased --from=-4096
  expect_throw "OUT_OF_BOUNDS": region.is_erased --to=-4096
  expect_throw "OUT_OF_BOUNDS": region.is_erased --from=4096 --to=0x7fff_f000
  expect_throw "OUT_OF_BOUNDS": region.is_erased --from=4096 --to=0
  region.close

test_region_flash_write_all:
  region := storage.Region.open --flash "region-1" --minimum_size=1000
  region.erase

  snippets := []
  written := 0
  while written < region.size:
    snippet_size := min ((random 128) + 1) (region.size - written)
    snippets.add (ByteArray snippet_size: random 0x100)
    region.write --from=written snippets.last
    written += snippet_size

  read := 0
  snippets.do: | snippet/ByteArray |
    expect_bytes_equal snippet (region.read --from=read --to=read + snippet.size)
    read += snippet.size
  region.close

test_region_flash_ignore_set:
  region := storage.Region.open --flash "region-2" --minimum_size=1000
  region.erase
  region.write --from=0 #[0b1010_1010]
  expect_bytes_equal #[0b1010_1010] (region.read --from=0 --to=1)
  region.write --from=0 #[0b1111_0000]
  expect_bytes_equal #[0b1010_0000] (region.read --from=0 --to=1)
  region.close

test_region_flash_invalid_arguments:
  expect_throw "ugh": storage.Region.open --flash "region-3"
      --minimum_access=storage.Region.ACCESS_WRITE_CAN_SET_BITS
  expect_throw "ugh2": storage.Region.open --flash "region-3"
      --maximum_erase_granularity=2048
  region := storage.Region.open --flash "region-3"
  region.close

test_region_flash_delete:
  region := storage.Region.open --flash "kurt" --minimum_size=8192
  expect_throw "ALREADY_IN_USE": storage.Region.delete --flash "kurt"
  region.close
  expect_throw "ALREADY_CLOSED": region.read --from=0 --to=4
  expect_throw "ALREADY_CLOSED": region.write --from=0 #[1]
  expect_throw "ALREADY_CLOSED": region.is_erased --from=0 --to=4
  expect_throw "ALREADY_CLOSED": region.erase --from=0 --to=4096
  storage.Region.delete --flash "kurt"

test_region_flash_list:
  regions := storage.Region.list --flash
  expect (regions.contains "flash:region-0")
  expect (regions.contains "flash:region-1")
  expect (regions.contains "flash:region-2")
  expect (regions.contains "flash:region-3")
  expect_not (regions.contains "flash:kurt")
