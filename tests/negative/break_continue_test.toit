// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo:
  while true:
    (:: break).call
    (:: continue).call
  unresolved

bar:
  while true:
    gee:
      (:: break).call
      (:: continue).call
      unresolved

gee [block]: block.call

main:
  break
  continue
  unresolved
