// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import fs
import system

import .utils

// Runs the tests for non-local branches at the highest optimization level.
// Wrong propagated types lead to wrong code when the optimizer uses them for
// tree shaking and for folding type checks, but these tests pass at the
// default optimization level even if the propagated types are wrong.

TESTS ::= [
  "non-local-branch-types-test.toit",
  "non-local-branch-regression-test.toit",
]

main args:
  toit-exe := ToitExecutable args
  tests-dir := fs.dirname (fs.dirname system.program-path)
  TESTS.do: | test/string |
    exit-code := toit-exe.run ["run", "-O2", "$tests-dir/$test"]
    expect-equals 0 exit-code
