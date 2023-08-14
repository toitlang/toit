// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import redirected.target as redirected
import sub
import foo
import expect show *

main:
  expect-equals "foo" foo.identify
  expect-equals "target" redirected.identify
  expect-equals "sub" sub.identify
