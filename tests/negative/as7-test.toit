// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  x := null
  x = "str"
  if Time.now.s-since-epoch == 0: x = 499
  x as int
