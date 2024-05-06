// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bar
import bar2
import foo
import foo2
import expect show *

main:
  expect-equals "bar" bar.identify
  expect-equals "bar2" bar2.identify
  expect-equals "foo" foo.identify
  expect-equals "foo2" foo2.identify
