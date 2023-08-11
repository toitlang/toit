// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Regression test for https://github.com/toitware/toit/issues/2856.

make-huge -> ByteArray:
  return ByteArray 12_000

class Thingy:

foo huge -> none:
  add-finalizer Thingy::
    // This finalizer lambda captures a huge ByteArray that dies in the same GC as
    // the Thingy.
    huge.size.repeat:
        huge[it] = random 255

main:
  foo make-huge

  repetitions := 10_000

  if platform == "FreeRTOS":
    repetitions = 1000

  repetitions.repeat:
    s := "foo" * 20  // Cause GC eventually.
    yield  // Run finalizers.

