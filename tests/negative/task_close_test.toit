// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  task::
    throw "nope"

  while true:
    sleep --ms=1000
    print "tada"
