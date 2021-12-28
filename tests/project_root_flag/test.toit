// Copyright (C) 2020 Toitware ApS. All rights reserved.

import redirected.target as redirected
import sub
import foo
import expect show *

main:
  expect_equals "foo" foo.identify
  expect_equals "target" redirected.identify
  expect_equals "sub" sub.identify
