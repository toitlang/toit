// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.storage
import encoding.tison
import expect show *
import .io-utils show FakeData

main:
  test-bucket-ram
  test-bucket-ram-large-payload
  test-bucket-ram-overflow
  test-bucket-flash
  test-bucket-flash-multi
  test-bucket-flash-large

  test-region-flash-open
  test-region-flash-double-open
  test-region-flash-erase
  test-region-flash-is-erased
  test-region-flash-write-all
  test-region-flash-write-io-data
  test-region-flash-ignore-set
  test-region-flash-out-of-space
  test-region-flash-stream
  test-region-flash-no-writable
  test-region-flash-large

  test-region-flash-delete
  test-region-flash-list

  test-region-partition
  test-region-partition-no-writable


test-bucket-ram:
  a := storage.Bucket.open --ram "bucket-a"
  b := storage.Bucket.open --ram "bucket-b"
  expect-throw "key not found": a["hest"]
  expect-throw "key not found": b["hest"]

  a["hest"] = 1234
  expect-equals 1234 a["hest"]
  expect-throw "key not found": b["hest"]

  expect-equals 2345 (set-helper b "hest" 2345)
  expect-equals 1234 a["hest"]
  expect-equals 2345 b["hest"]

  alias := storage.Bucket.open "ram:bucket-a"
  expect-equals 1234 alias["hest"]
  alias.close

  non-alias := storage.Bucket.open "flash:bucket-a"
  expect-throw "key not found": non-alias["hest"]
  non-alias.close

  a.remove "hest"
  expect-throw "key not found": a["hest"]
  expect-equals 2345 b["hest"]

  b.remove "hest"
  expect-throw "key not found": a["hest"]
  expect-throw "key not found": b["hest"]

// We're only allowed to get the value of assignments
// in certain positions, so we use a helper for this.
set-helper bucket key value:
  return bucket[key] = value

test-bucket-ram-large-payload:
  // The storage service may keep a cache with the
  // store entries around and it is important that
  // it does not send the values directly over the
  // RPC boundary, because that leads to neutering
  // of large byte arrays.
  a := storage.Bucket.open --ram "bucket-a"
  long := List 16: "1234" * 8
  expect (tison.encode long).size > 256
  a["fisk"] = long
  expect-equals long a["fisk"]
  expect-equals long a["fisk"]
  a.close

test-bucket-ram-overflow:
  a := storage.Bucket.open --ram "bucket-a"
  expect-throw "OUT_OF_SPACE": a["fisk"] = "12345678" * 1024
  stored := []
  try:
    256.repeat: | index |
      exception := catch:
        key := "$(%03x index)"
        a[key] = key * 8
        stored.add key
      if exception:
        expect-equals "OUT_OF_SPACE" exception
  finally:
    expect stored.size > 16
    stored.do:
      expect-equals (it * 8) a[it]
      a.remove it

test-bucket-flash:
  bucket := storage.Bucket.open --flash "bucket"
  bucket.remove "hest"
  expect-throw "key not found": bucket["hest"]

  expect-equals 42 (bucket.get "hest" --if-absent=: 42)
  expect-equals 87 (bucket.get "hest" --init=: 87)
  expect-equals 87 bucket["hest"]

  // Explicitly storing to the bucket from an --if-absent block is
  // a bit of anti-pattern (using --init is nicer), but it is not
  // that uncommon and it should work.
  bucket.remove "fisk"
  expect-equals 99 (bucket.get "fisk" --if-absent=: bucket["fisk"] = 99)
  expect-equals 99 bucket["fisk"]

  expect-equals 1234 (set-helper bucket "fisk" 1234)
  expect-equals 1234 bucket["fisk"]
  bucket.remove "fisk"

  alias := storage.Bucket.open "flash:bucket"
  expect-equals 87 alias["hest"]
  alias.close

  non-alias := storage.Bucket.open "ram:bucket"
  expect-throw "key not found": non-alias["hest"]
  non-alias.close

  bucket.remove "hest"
  expect-throw "key not found": bucket["hest"]

  expect-throw "key not found": bucket[""]
  bucket[""] = 1234
  expect-equals 1234 bucket[""]
  bucket.remove ""
  expect-throw "key not found": bucket[""]

  long := "2357" * 8
  bucket[long] = 2345
  expect-equals 2345 bucket[long]
  bucket.remove long
  expect-throw "key not found": bucket[long]

test-bucket-flash-multi:
  b1 := storage.Bucket.open --flash "gris"
  b2 := storage.Bucket.open --flash "gris"
  b1["fisk"] = 1234
  b1["hest"] = 2345
  expect-equals 1234 b2["fisk"]
  b2.remove "fisk"
  expect-null (b1.get "fisk")
  b1.close
  expect-equals 2345 b2["hest"]

test-bucket-flash-large:
  bucket := storage.Bucket.open --flash "hund"
  content := List 32:
    ByteArray 512 + (random 512): random 0x100
  content.size.repeat: bucket["entry$it"] = content[it]
  content.size.repeat: expect-bytes-equal content[it] bucket["entry$it"]
  // Make sure that writes do not invalidate previously written
  // entries because of weird cache neutering issues.
  bucket["42"] = 87
  bucket.close
  // Re-open the bucket to force this to be read from flash again.
  bucket = storage.Bucket.open --flash "hund"
  content.size.repeat: expect-bytes-equal content[it] bucket["entry$it"]
  bucket.close

test-region-flash-open:
  storage.Region.delete --flash "region-0"
  expect-throw "FILE_NOT_FOUND": storage.Region.open --flash "region-0"
  region := storage.Region.open --flash "region-0" --capacity=500
  region.close
  expect-throw "Existing region is too small":
    storage.Region.open --flash "region-0" --capacity=16000
  storage.Region.delete --flash "region-0"

test-region-flash-double-open:
  region := storage.Region.open --flash "region-0" --capacity=1000
  expect-throw "ALREADY_IN_USE": storage.Region.open --flash "region-0" --capacity=1000
  region.close
  storage.Region.delete --flash "region-0"

test-region-flash-erase:
  region := storage.Region.open --flash "region-0" --capacity=8000
  expect-equals 8192 region.size
  expect-equals 4096 region.erase-granularity
  expect-equals 0xff region.erase-value
  region.is-erased
  expect region.is-erased
  expect ((region.read --from=0 --to=region.size).every: it == region.erase-value)

  expect-throw "Bad Argument": region.erase --from=1
  expect-throw "Bad Argument": region.erase --to=9
  expect-throw "OUT_OF_BOUNDS": region.erase --from=0 --to=0
  expect-throw "OUT_OF_BOUNDS": region.erase --from=-4096
  expect-throw "OUT_OF_BOUNDS": region.erase --to=-4096
  expect-throw "OUT_OF_BOUNDS": region.erase --from=4096 --to=0x7fff_f000
  expect-throw "OUT_OF_BOUNDS": region.erase --from=4096 --to=0
  region.close

test-region-flash-is-erased:
  region := storage.Region.open --flash "region-1" --capacity=1000
  region.erase
  expect region.is-erased

  expect (region.is-erased --from=1 --to=31)
  expect (region.is-erased --from=4 --to=31)
  expect (region.is-erased --from=1 --to=28)
  expect (region.is-erased --from=4 --to=28)

  region.write --at=3 #[1]
  expect-not (region.is-erased --from=1 --to=31)
  expect (region.is-erased --from=4 --to=31)
  expect-not (region.is-erased --from=1 --to=28)
  expect (region.is-erased --from=4 --to=28)

  region.write --at=29 #[2]
  expect-not (region.is-erased --from=1 --to=31)
  expect-not (region.is-erased --from=4 --to=31)
  expect-not (region.is-erased --from=1 --to=28)
  expect (region.is-erased --from=4 --to=28)

  region.write --at=17 #[2]
  expect-not (region.is-erased --from=1 --to=31)
  expect-not (region.is-erased --from=4 --to=31)
  expect-not (region.is-erased --from=1 --to=28)
  expect-not (region.is-erased --from=4 --to=28)

  expect-throw "OUT_OF_BOUNDS": region.is-erased --from=0 --to=0
  expect-throw "OUT_OF_BOUNDS": region.is-erased --from=-4096
  expect-throw "OUT_OF_BOUNDS": region.is-erased --to=-4096
  expect-throw "OUT_OF_BOUNDS": region.is-erased --from=4096 --to=0x7fff_f000
  expect-throw "OUT_OF_BOUNDS": region.is-erased --from=4096 --to=0
  region.close

test-region-flash-write-all:
  region := storage.Region.open --flash "region-1" --capacity=1000
  region.erase

  snippets := []
  written := 0
  while written < region.size:
    snippet-size := min ((random 128) + 1) (region.size - written)
    snippets.add (ByteArray snippet-size: random 0x100)
    region.write --at=written snippets.last
    written += snippet-size

  read := 0
  snippets.do: | snippet/ByteArray |
    expect-bytes-equal snippet (region.read --from=read --to=read + snippet.size)
    read += snippet.size
  region.close

test-region-flash-write-io-data:
  region := storage.Region.open --flash "region-1" --capacity=1000

  region.erase
  region.write --at=0 "foo"
  expect-equals #['f', 'o', 'o'] (region.read --from=0 --to=3)

  region.erase
  region.write --at=0 (FakeData "bar")
  expect-equals #['b', 'a', 'r'] (region.read --from=0 --to=3)

  region.close

test-region-flash-ignore-set:
  region := storage.Region.open --flash "region-2" --capacity=1000
  region.erase
  region.write --at=0 #[0b1010_1010]
  expect-bytes-equal #[0b1010_1010] (region.read --from=0 --to=1)
  region.write --at=0 #[0b1111_0000]
  expect-bytes-equal #[0b1010_0000] (region.read --from=0 --to=1)
  region.close

test-region-flash-out-of-space:
  expect-throw "OUT_OF_SPACE": storage.Region.open --flash "region-3" --capacity=1 << 30
  regions := []
  try:
    256.repeat: | index |
      exception := catch:
        regions.add (storage.Region.open --flash "too-much-$index" --capacity=32 * 1024)
      if exception:
        expect-equals "OUT_OF_SPACE" exception
  finally:
    expect regions.size > 16
    regions.do:
      it.close
      storage.Region.delete it.uri

test-region-flash-stream:
  region := storage.Region.open --flash "region-1" --capacity=1000
  try:
    test-region-flash-stream region null
    [ 0, 1, 8, 17, 199, 256, 512, 999, 1000, 1001, 10000 ].do:
      test-region-flash-stream region it
  finally:
    region.close

test-region-flash-stream region/storage.Region max-size/int?:
  region.erase
  bytes-written := ByteArray region.size: random 0x100
  region.write --at=0 bytes-written

  if max-size and max-size < 16:
    expect-throw "Bad Argument": region.stream --max-size=max-size
    return

  expect-bytes-equal
      bytes-written
      (region.stream --max-size=max-size).read-bytes region.size

  indexes := [-100, -1, 0, 1, 7, 99, 500, 512, 999, 1000, 1001, 10000]
  indexes.do: | from/int |
    indexes.do: | to/int |
      if 0 <= from <= to <= bytes-written.size:
        reader := region.stream --from=from --to=to --max-size=max-size
        bytes-read := reader.read-bytes to - from
        expect-bytes-equal bytes-written[from..to] bytes-read
      else:
        expect-throw "OUT_OF_BOUNDS":
          region.stream  --from=from --to=to --max-size=max-size

  64.repeat:
    reader := region.stream --from=it --max-size=max-size
    n := reader.read.size
    cursor := n + it
    expect-equals (round-up cursor 16) cursor

test-region-flash-no-writable:
  region := storage.Region.open --flash "region-1" --capacity=1000 --no-writable
  expect-throw "PERMISSION_DENIED": region.erase
  expect-throw "PERMISSION_DENIED": region.write --at=0 #[0b1010_1010]
  region.read --from=0 --to=1
  region.close

test-region-flash-large:
  capacity := 60_000_000  // Roughly 60 MB.
  region := storage.Region.open --flash "region-large" --capacity=capacity
  region.erase
  content := ByteArray capacity
  1000.repeat:
    content[random capacity] = random 0x100
  content[0] = 42
  content[capacity - 1] = 0x42
  region.write --at=0 content
  region.close
  region = storage.Region.open --flash "region-large" --capacity=capacity
  stored := region.read --from=0 --to=capacity
  expect-equals content stored
  region.close

test-region-flash-delete:
  region := storage.Region.open --flash "region-3" --capacity=8192
  expect-throw "ALREADY_IN_USE": storage.Region.delete --flash "region-3"
  region.close
  expect-throw "ALREADY_CLOSED": region.read --from=0 --to=4
  expect-throw "ALREADY_CLOSED": region.write --at=0 #[1]
  expect-throw "ALREADY_CLOSED": region.is-erased --from=0 --to=4
  expect-throw "ALREADY_CLOSED": region.erase --from=0 --to=4096
  storage.Region.delete --flash "region-3"

test-region-flash-list:
  regions := storage.Region.list --flash
  expect (regions.contains "flash:region-0")
  expect (regions.contains "flash:region-1")
  expect (regions.contains "flash:region-2")
  expect-not (regions.contains "flash:region-3")

test-region-partition:
  // TODO(kasper): Extend testing.
  region := storage.Region.open --partition "partition-0"
  expect-throw "ALREADY_IN_USE": storage.Region.open --partition "partition-0"
  region.close

test-region-partition-no-writable:
  region := storage.Region.open --partition "partition-0" --no-writable
  expect-throw "PERMISSION_DENIED": region.erase
  expect-throw "PERMISSION_DENIED": region.write --at=0 #[0b1010_1010]
  region.read --from=0 --to=1
  region.close
