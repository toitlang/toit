// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  // This is just a lookup failure, since the syntax is similar to a call, like
  // in `0.abs`
  print 0_.123456
  unresolved
