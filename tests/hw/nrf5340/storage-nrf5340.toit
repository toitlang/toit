// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
import gpio
import zephyr
import system.storage
import expect show *
import ...storage-test as common

main:
  ack := gpio.Pin 33 --input --pull-down
  phase-pin := gpio.Pin 32 --input
  phase := phase-pin.get
  phase-pin.close
  sleep --ms=100
  sequence := 0
  request := : | command/string |
    sequence++
    print "GPIO REQUEST $sequence $command"
    with-timeout --ms=5000: ack.wait-for (sequence & 1)

  if phase == 0:
    clean-up
    common.test-bucket-ram
    common.test-bucket-ram-large-payload
    common.test-bucket-ram-overflow
    common.test-bucket-flash
    common.test-bucket-flash-multi
    print "STORAGE RAM and flash bucket API PASS"
    common.test-region-flash-open
    common.test-region-flash-double-open
    common.test-region-flash-erase
    common.test-region-flash-is-erased
    common.test-region-flash-write-all
    common.test-region-flash-write-io-data
    common.test-region-flash-ignore-set
    common.test-region-flash-no-writable
    common.test-region-flash-delete
    print "STORAGE raw region API PASS"
    clean-up
    test-boundaries
    test-capacity
    prepare-persistent
    request.call "CONFIG 13 OUT 1"
    print "STORAGE SOFTWARE RESET REQUEST"
    zephyr.reset
    throw "reset returned"

  expect (zephyr.reset-reason & zephyr.RESET-SOFTWARE != 0)
  verify-persistent
  print "STORAGE reboot persistence PASS"
  indicator := gpio.Pin 8 --output --value=1
  request.call "WAIT 18 1"
  print "NRF5340 STORAGE PASS"

clean-up:
  ["region-0", "region-1", "region-2", "region-3", "nrf-raw"].do:
    storage.Region.delete --flash it
  // The common tests use fixed bucket names. Remove only their own keys.
  {"bucket-a": ["hest"], "bucket": ["hest", "fisk", ""], "gris": ["fisk", "hest"]}.do:
      | name keys |
    bucket := storage.Bucket.open --flash name
    keys.do: bucket.remove it
    bucket.close

test-boundaries:
  region := storage.Region.open --flash "nrf-raw" --capacity=8192
  region.erase
  expected := ByteArray region.size --initial=0xff
  // Flash literals, unaligned slices and writes spanning a page boundary.
  region.write --at=0 "Toit"
  expected.replace 0 "Toit"
  bytes := ByteArray 43: it * 3
  slice := bytes[1..42]
  region.write --at=4093 slice
  expected.replace 4093 slice
  expect-bytes-equal expected (region.read --from=0 --to=region.size)
  // More updates than NVMC permits without erasing a word. Preserve every
  // neighboring byte, including bytes outside the requested range.
  start := Time.monotonic-us
  [0xfe, 0xfc, 0xf8, 0xf0, 0xe0, 0xc0, 0x80, 0].do: | value |
    region.write --at=99 #[value]
    expected[99] = value
    expect-bytes-equal expected (region.read --from=0 --to=region.size)
  print "STORAGE eight byte updates took $((Time.monotonic-us - start) / 1000) ms"
  region.write --at=99 #[0xff]
  expect-bytes-equal expected (region.read --from=0 --to=region.size)
  expect (region.is-erased --from=97 --to=99)
  expect-throw "OUT_OF_BOUNDS": region.write --at=-1 #[0]
  expect-throw "OUT_OF_BOUNDS": region.write --at=8192 #[0]
  expect-throw "OUT_OF_BOUNDS": region.read --from=0 --to=8193
  expect-throw "ALREADY_IN_USE": storage.Region.delete --flash "nrf-raw"
  region.erase --from=0 --to=4096
  expected.replace 0 (ByteArray 4096 --initial=0xff)
  expect-bytes-equal expected (region.read --from=0 --to=region.size)
  region.close
  storage.Region.delete --flash "nrf-raw"
  print "STORAGE page boundaries, repeated writes and protection PASS"

test-capacity:
  regions := []
  try:
    for index := 0; index < 32; index++:
      error := catch:
        regions.add (storage.Region.open --flash "nrf-fill-$index" --capacity=8192)
      if error:
        expect-equals "OUT_OF_SPACE" error
        break
    expect (1 <= regions.size < 32)
  finally:
    regions.do:
      it.close
      storage.Region.delete it.uri
  print "STORAGE capacity limit and reclamation PASS"

prepare-persistent:
  storage.Region.delete --flash "nrf-persistent"
  region := storage.Region.open --flash "nrf-persistent" --capacity=8192
  region.erase
  region.write --at=0 (ByteArray 8192: (it * 17 + 3) & 0xff)
  region.close
  bucket := storage.Bucket.open --flash "nrf-persistent"
  bucket["large"] = ByteArray 8197: (it * 23 + 5) & 0xff
  bucket["other"] = ByteArray 5003: (it * 11 + 7) & 0xff
  bucket["generation"] = 42
  alias := storage.Bucket.open --flash "nrf-persistent"
  alias["generation"] = 43
  expect-equals 43 bucket["generation"]
  alias.close
  bucket.close
  child := spawn::
    verify-persistent
    child-bucket := storage.Bucket.open --flash "nrf-persistent"
    child-bucket["child"] = "RPC survived"
    // Deliberately leave the bucket open for process cleanup.
  with-timeout --ms=5000:
    while not (catch: child.priority): sleep --ms=1
  bucket = storage.Bucket.open --flash "nrf-persistent"
  expect-equals "RPC survived" bucket["child"]
  bucket.close
  verify-persistent
  print "STORAGE multi-page buckets, aliases and child process PASS"

verify-persistent:
  bucket := storage.Bucket.open --flash "nrf-persistent"
  expect-equals 43 bucket["generation"]
  expect-bytes-equal (ByteArray 8197: (it * 23 + 5) & 0xff) bucket["large"]
  expect-bytes-equal (ByteArray 5003: (it * 11 + 7) & 0xff) bucket["other"]
  bucket.close
  region := storage.Region.open --flash "nrf-persistent" --no-writable
  expect-bytes-equal (ByteArray 8192: (it * 17 + 3) & 0xff) (region.read --from=0 --to=8192)
  region.close
