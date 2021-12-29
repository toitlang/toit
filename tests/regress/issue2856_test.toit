// Copyright (C) 2020 Toitware ApS. All rights reserved.

// Regression test for https://github.com/toitware/toit/issues/2856.

make_huge -> ByteArray:
  return ByteArray 12_000

class Thingy:

foo huge -> none:
  add_finalizer Thingy::
    // This finalizer lambda captures a huge ByteArray that dies in the same GC as
    // the Thingy.
    huge.size.repeat:
        huge[it] = random 255

main:
  foo make_huge

  repetitions := 10_000

  if platform == "FreeRTOS":
    repetitions = 1000

  repetitions.repeat:
    s := "foo" * 20  // Cause GC eventually.
    yield  // Run finalizers.

