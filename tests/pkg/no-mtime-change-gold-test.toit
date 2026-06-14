// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file

import .gold-tester

main args:
  with-gold-tester --with-git-pkg-registry args: test it

test tester/GoldTester:
  lock-path := "$tester.working-dir/package.lock"
  stat-before := file.stat lock-path
  mtime-before := stat-before[file.ST-MTIME]

  tester.gold "10-test" [
    ["pkg", "install"],
    ["// Just install doesn't add the missing dependency in the lock file."],
    ["exec", "main.toit"],
  ]

  stat-after := file.stat lock-path
  mtime-after := stat-after[file.ST-MTIME]

  expect-equals mtime-before mtime-after
