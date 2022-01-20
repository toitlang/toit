// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class B:
  constructor.foobar:
  // Make sure there isn't any error here.
  // We had a small bug where we claimed that these two constructors
  // were overlapping.
  constructor.foobar a b=0:

main:
  // This test is mainly a health-test. So nothing really to check.
  b := B.foobar
