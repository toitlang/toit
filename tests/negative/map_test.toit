// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  x := {
    1 :
  }
  unresolved

  x = {
    1 : unresolved,
    unresolved
  }

  x = {
    unresolved : true,
    break 499
  }
