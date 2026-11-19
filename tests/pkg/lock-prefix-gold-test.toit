// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester args --with-git-pkg-registry: test it

test tester/GoldTester:
  tester.gold "10-prefix" [
    ["pkg", "init"],
    ["pkg", "install", "--prefix=old", "pkg2@1"],
    ["pkg", "install", "pkg2@1"],
    ["// Both majors of pkg2 end up in the solution."],
    ["pkg", "update", "--major", "pkg2"],
    ["// 'pkg2' must use the version the update picked (major 2)."],
    ["package.yaml"],
    ["package.lock"],
  ]
