// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import reader show BufferedReader
import system.storage
import encoding.tison
import expect show *

main:
  test_bucket_ram
  test_bucket_ram_large_payload
  test_bucket_ram_overflow
  test_bucket_flash

  test_region_flash_open
  test_region_flash_double_open
  test_region_flash_erase
  test_region_flash_is_erased
  test_region_flash_write_all
  test_region_flash_ignore_set
  test_region_flash_out_of_space
  test_region_flash_stream

  test_region_flash_delete
  test_region_flash_list

  test_region_partition

test_bucket_ram:
  a := storage.Bucket.open --ram "bucket-a"
  b := storage.Bucket.open --ram "bucket-b"
  expect_throw "key not found": a["hest"]
  expect_throw "key not found": b["hest"]

  a["hest"] = 1234
  expect_equals 1234 a["hest"]
  expect_throw "key not found": b["hest"]

  expect_equals 2345 (set_helper b "hest" 2345)
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

// We're only allowed to get the value of assignments
// in certain positions, so we use a helper for this.
set_helper bucket key value:
  return bucket[key] = value

test_bucket_ram_large_payload:
  // The storage service may keep a cache with the
  // store entries around and it is important that
  // it does not send the values directly over the
  // RPC boundary, because that leads to neutering
  // of large byte arrays.
  a := storage.Bucket.open --ram "bucket-a"
  long := List 16: "1234" * 8
  expect (tison.encode long).size > 256
  a["fisk"] = long
  expect_equals long a["fisk"]
  expect_equals long a["fisk"]
  a.close

test_bucket_ram_overflow:
  a := storage.Bucket.open --ram "bucket-a"
  expect_throw "OUT_OF_SPACE": a["fisk"] = "12345678" * 1024
  stored := []
  try:
    256.repeat: | index |
      exception := catch:
        key := "$(%03x index)"
        a[key] = key * 8
        stored.add key
      if exception:
        expect_equals "OUT_OF_SPACE" exception
  finally:
    expect stored.size > 16
    stored.do:
      expect_equals (it * 8) a[it]
      a.remove it

test_bucket_flash:
  bucket := storage.Bucket.open --flash "bucket"
  bucket.remove "hest"
  expect_throw "key not found": bucket["hest"]

  expect_equals 42 (bucket.get "hest" --if_absent=: 42)
  expect_equals 87 (bucket.get "hest" --init=: 87)
  expect_equals 87 bucket["hest"]

  // Explicitly storing to the bucket from an --if_absent block is
  // a bit of anti-pattern (using --init is nicer), but it is not
  // that uncommon and it should work.
  bucket.remove "fisk"
  expect_equals 99 (bucket.get "fisk" --if_absent=: bucket["fisk"] = 99)
  expect_equals 99 bucket["fisk"]

  expect_equals 1234 (set_helper bucket "fisk" 1234)
  expect_equals 1234 bucket["fisk"]
  bucket.remove "fisk"

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

test_region_flash_open:
  storage.Region.delete --flash "region-0"
  expect_throw "FILE_NOT_FOUND": storage.Region.open --flash "region-0"
  region := storage.Region.open --flash "region-0" --capacity=500
  region.close
  expect_throw "Existing region is too small":
    storage.Region.open --flash "region-0" --capacity=16000
  storage.Region.delete --flash "region-0"

test_region_flash_double_open:
  region := storage.Region.open --flash "region-0" --capacity=1000
  expect_throw "ALREADY_IN_USE": storage.Region.open --flash "region-0" --capacity=1000
  region.close
  storage.Region.delete --flash "region-0"

test_region_flash_erase:
  region := storage.Region.open --flash "region-0" --capacity=8000
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
  region := storage.Region.open --flash "region-1" --capacity=1000
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
  region := storage.Region.open --flash "region-1" --capacity=1000
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
  region := storage.Region.open --flash "region-2" --capacity=1000
  region.erase
  region.write --from=0 #[0b1010_1010]
  expect_bytes_equal #[0b1010_1010] (region.read --from=0 --to=1)
  region.write --from=0 #[0b1111_0000]
  expect_bytes_equal #[0b1010_0000] (region.read --from=0 --to=1)
  region.close

test_region_flash_out_of_space:
  expect_throw "OUT_OF_SPACE": storage.Region.open --flash "region-3" --capacity=1 << 30
  regions := []
  try:
    256.repeat: | index |
      exception := catch:
        regions.add (storage.Region.open --flash "too-much-$index" --capacity=32 * 1024)
      if exception:
        expect_equals "OUT_OF_SPACE" exception
  finally:
    expect regions.size > 16
    regions.do:
      it.close
      storage.Region.delete it.uri

test_region_flash_stream:
  region := storage.Region.open --flash "region-1" --capacity=1000
  try:
    test_region_flash_stream region null
    [ 0, 1, 8, 17, 199, 256, 512, 999, 1000, 1001, 10000 ].do:
      test_region_flash_stream region it
  finally:
    region.close

test_region_flash_stream region/storage.Region max_size/int?:
  region.erase
  bytes_written := ByteArray region.size: random 0x100
  region.write --from=0 bytes_written

  if max_size and max_size < 16:
    expect_throw "Bad Argument": region.stream --max_size=max_size
    return

  expect_bytes_equal
      bytes_written
      (BufferedReader (region.stream --max_size=max_size)).read_bytes region.size

  indexes := [-100, -1, 0, 1, 7, 99, 500, 512, 999, 1000, 1001, 10000]
  indexes.do: | from/int |
    indexes.do: | to/int |
      if 0 <= from <= to <= bytes_written.size:
        reader := region.stream --from=from --to=to --max_size=max_size
        buffered := BufferedReader reader
        bytes_read := buffered.read_bytes to - from
        expect_bytes_equal bytes_written[from..to] bytes_read
      else:
        expect_throw "OUT_OF_BOUNDS":
          region.stream  --from=from --to=to --max_size=max_size

  64.repeat:
    reader := region.stream --from=it --max_size=max_size
    n := reader.read.size
    cursor := n + it
    expect_equals (round_up cursor 16) cursor

test_region_flash_delete:
  region := storage.Region.open --flash "region-3" --capacity=8192
  expect_throw "ALREADY_IN_USE": storage.Region.delete --flash "region-3"
  region.close
  expect_throw "ALREADY_CLOSED": region.read --from=0 --to=4
  expect_throw "ALREADY_CLOSED": region.write --from=0 #[1]
  expect_throw "ALREADY_CLOSED": region.is_erased --from=0 --to=4
  expect_throw "ALREADY_CLOSED": region.erase --from=0 --to=4096
  storage.Region.delete --flash "region-3"

test_region_flash_list:
  regions := storage.Region.list --flash
  expect (regions.contains "flash:region-0")
  expect (regions.contains "flash:region-1")
  expect (regions.contains "flash:region-2")
  expect_not (regions.contains "flash:region-3")

test_region_partition:
  // TODO(kasper): Extend testing.
  region := storage.Region.open --partition "partition-0"
  expect_throw "ALREADY_IN_USE": storage.Region.open --partition "partition-0"
  region.close
