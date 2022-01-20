// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

test_set:
  s := Set
  500.repeat: s.add it

  // Make a gap in the backing big enough to trigger a
  // tombstone with a skip value.  This will cause a
  // bailout from the C++ code to the Toit code in the
  // do method.  Ensure that we continue at the correct
  // index in this case.
  for i := 240; i < 260; i++:
    s.remove i
    s2 := Set
    s.do:
      expect (not (s2.contains it))
      s2.add it
    expect_equals s.size s2.size
    s3 := Set
    s.do --reversed:
      expect (not (s3.contains it))
      s3.add it
    expect_equals s.size s3.size

test_map:
  m := Map
  500.repeat: m[it] = it * 2

  // Make a gap in the backing big enough to trigger a
  // tombstone with a skip value.  This will cause a
  // bailout from the C++ code to the Toit code in the
  // do method.  Ensure that we continue at the correct
  // index in this case.
  for i := 240; i < 260; i++:
    m.remove i
    s2 := Set
    m.do:
      expect (not (s2.contains it))
      s2.add it
    expect_equals m.size s2.size
    s3 := Set
    m.do --reversed:
      expect (not (s3.contains it))
      s3.add it
    expect_equals m.size s3.size

main:
  test_set
  test_map
