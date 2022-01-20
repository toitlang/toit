// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  x := null
  x = "str"
  if Time.now.s_since_epoch == 0: x = 499
  x as int
