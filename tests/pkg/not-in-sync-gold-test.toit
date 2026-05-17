// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file

import .gold-tester

main args:
  with-gold-tester args --with-git-pkg-registry: test it

test tester/GoldTester:
  tester.gold "00-setup" [
    ["pkg", "init"],
    ["pkg", "install", "pkg1"],
    ["pkg", "install", "pkg2"],
  ]

  // Replace the package.yaml file with an empty one.
  package-path := "$tester.working-dir/package.yaml"
  lock-path := "$tester.working-dir/package.lock"
  file.delete package-path
  file.write-contents --path=package-path ""

  tester.gold "10-more-lock" [
    ["// Should error, as the lock file has more entries"],
    ["pkg", "install", "pkg3"],
  ]

  file.delete package-path
  file.delete lock-path

  tester.run [
    ["pkg", "init"],
    ["pkg", "install", "pkg1"],
  ]

  lock-contents := file.read-contents lock-path

  tester.run [
    ["pkg", "install", "pkg2"],
  ]

  file.delete lock-path
  file.write-contents --path=lock-path lock-contents

  tester.gold "20-more-package" [
    ["pkg", "install", "pkg3"],
  ]
