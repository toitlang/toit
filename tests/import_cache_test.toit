// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// We get can get 'bar' from both import_cache1 and import_cache2.
import .import_cache1
// The real test is in import_cache2.
import .import_cache2

main:
  expect_equals "bar" bar
  // The implicitly imported 'int' should only be found in `core`.
  // However, we will do a lookup for it in 'import_cache2', and will record
  //   that it can't be found there.
  // A later lookup of `int` inside the module must still succeed and find
  //   the implicitly imported 'int' from the core library.
  local /int := 499
