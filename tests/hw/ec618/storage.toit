// Tests flash and RAM storage buckets on EC618.

import system.storage

main:
  // Heartbeat task to detect freezes.
  task::
    while true:
      print "[heartbeat] alive"
      sleep --ms=2000

  test-ram-bucket
  test-flash-bucket
  print "ALL STORAGE TESTS PASSED"

test-ram-bucket:
  bucket := storage.Bucket.open --ram "test/ram"
  try:
    // Write and read back.
    bucket["key1"] = #[1, 2, 3, 4]
    value := bucket["key1"]
    assert-equals #[1, 2, 3, 4] value

    // Overwrite.
    bucket["key1"] = #[5, 6, 7]
    value = bucket["key1"]
    assert-equals #[5, 6, 7] value

    // Multiple keys.
    bucket["key2"] = #[10, 20]
    assert-equals #[5, 6, 7] bucket["key1"]
    assert-equals #[10, 20] bucket["key2"]

    // Remove.
    bucket.remove "key1"
    assert-equals null (bucket.get "key1")
    assert-equals #[10, 20] bucket["key2"]

    print "  RAM bucket: OK"
  finally:
    bucket.close

test-flash-bucket:
  bucket := storage.Bucket.open --flash "test/flash"
  try:
    // Clean up from previous runs.
    bucket.remove "persistent-key"

    // Write and read back.
    bucket["persistent-key"] = #[0xDE, 0xAD, 0xBE, 0xEF]
    value := bucket["persistent-key"]
    assert-equals #[0xDE, 0xAD, 0xBE, 0xEF] value

    // Overwrite.
    bucket["persistent-key"] = #[0xCA, 0xFE]
    value = bucket["persistent-key"]
    assert-equals #[0xCA, 0xFE] value

    // Clean up.
    bucket.remove "persistent-key"
    assert-equals null (bucket.get "persistent-key")

    print "  flash bucket: OK"
  finally:
    bucket.close

assert-equals expected actual:
  if expected != actual:
    throw "Expected $expected, got $actual"
