// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
// TEST_FLAGS: --force

import expect show *


foo --no-x:

main:
  no := 33
  x := 42
  --no-x
