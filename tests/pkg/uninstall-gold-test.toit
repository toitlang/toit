// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester --with-git-pkg-registry args: test it

test tester/GoldTester:
  tester.gold "10-init" [
    ["pkg", "init"],
  ]

  tester.gold "20-test" [
    ["pkg", "install", "pkg1"],
    ["pkg", "install", "pkg2"],
    ["package.yaml"],
    ["package.lock"],
    ["pkg", "uninstall", "pkg1"],
    ["// Can't uninstall pkg1 again."],
    ["pkg", "uninstall", "pkg1"],
    ["pkg", "uninstall", "pkg2"],
    ["package.yaml"],
    ["package.lock"],
    ["pkg", "install", "--prefix", "foo", "pkg1"],
    ["// Can't uninstall with package name."],
    ["pkg", "uninstall", "pkg1"],
    ["// But uninstalling with prefix works."],
    ["pkg", "uninstall", "foo"],
    ["package.yaml"],
    ["package.lock"],
  ]
