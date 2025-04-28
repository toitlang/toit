// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
// TEST_FLAGS: --force

import expect show *

foo --named:

main:
  foo --named=1 --named=2
