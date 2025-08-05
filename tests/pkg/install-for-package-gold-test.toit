// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file

import .gold-tester

main args:
  with-gold-tester --with-git-pkg-registry args: test it

test tester/GoldTester:
  tester.gold "00-test" [
    ["pkg", "init"],
    ["pkg", "install", "pkg1"],
    ["pkg", "install", "pkg2"],
    ["package.lock"],
    ["package.yaml"]
  ]

  lock-path := "$tester.working-dir/package.lock"
  package-path := "$tester.working-dir/package.yaml"

  expect (file.is-file lock-path)
  expect (file.is-file package-path)

  file.delete "$tester.working-dir/package.lock"

  tester.gold "10-test" [
    ["pkg", "install"],
    ["package.lock"],
    ["package.yaml"],
  ]
