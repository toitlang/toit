// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import host.directory

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  tester.gold "10-init" [
    ["pkg", "init"],
  ]

  nested := "$tester.working-dir/nested"
  directory.mkdir nested
  directory.chdir nested

  tester.gold --no-set-project-root "20-test" [
    ["pkg", "install", "github.com/toitware/toit-morse"],
  ]
