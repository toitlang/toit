// Tests multi-page flash bucket storage on EC618.
// Writes values larger than a single flash page (4KB) to exercise
// the non-header-pages code path.

import system.storage

main:
  bucket := storage.Bucket.open --flash "test/multipage"
  try:
    // Small value (fits in header page).
    small := ByteArray 100: it & 0xff
    bucket["small"] = small
    assert-equals small (bucket.get "small")
    print "  small value: OK"

    // Large value (spans multiple pages).
    large := ByteArray 8000: (it * 7) & 0xff
    bucket["large"] = large
    read-back := bucket.get "large"
    assert-equals large.size read-back.size
    large.size.repeat: | i |
      if read-back[i] != large[i]: throw "mismatch at $i: expected $large[i] got $read-back[i]"
    print "  large value ($large.size bytes): OK"

    // Multiple large values.
    val1 := ByteArray 5000: (it * 3) & 0xff
    val2 := ByteArray 6000: (it * 5) & 0xff
    bucket["v1"] = val1
    bucket["v2"] = val2
    assert-equals val1 (bucket.get "v1")
    assert-equals val2 (bucket.get "v2")
    print "  multiple large values: OK"

    // Clean up.
    bucket.remove "small"
    bucket.remove "large"
    bucket.remove "v1"
    bucket.remove "v2"

    print "MULTIPAGE STORAGE TEST PASSED"
  finally:
    bucket.close

assert-equals expected actual:
  if expected != actual:
    throw "Expected $expected, got $actual"
