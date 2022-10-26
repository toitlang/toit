// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor show Latch

main:
  latch := Latch
  task::
    catch:
      try:
        throw 123456
      finally: | is_exception exception |
        latch.set --exception exception
  latch.get
