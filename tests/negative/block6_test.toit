// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo [x] y:
  x.call y unresolved

main:
  b := (: it)
  foo b 499
  unresolved

