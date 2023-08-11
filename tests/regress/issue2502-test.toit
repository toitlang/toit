// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
    expect.expect-equals "inner: set" inner
    expect.expect-equals "outer: set" outer
