// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  count := 3
  count.repeat:
    task --background::
      10000.repeat:
        yield
      count--

  while count > 0:
    sleep --ms=10

  print "All done"
