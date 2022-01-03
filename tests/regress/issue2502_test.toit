// Copyright (C) 2020 Toitware ApS. All rights reserved.

// Regression test for https://github.com/toitware/toit/issues/2502.

import expect

main:
  inner := "inner: not set"
  outer := "outer: not set"
  try:
    outer = catch:
      try:
        throw "outer: set"
      finally:
        inner = catch:
          throw "inner: set"
  finally:
    expect.expect_equals "inner: set" inner
    expect.expect_equals "outer: set" outer
