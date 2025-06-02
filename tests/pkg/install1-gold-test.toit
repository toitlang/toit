// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester --with-git-pkg-registry args: test it

test tester/GoldTester:
  tester.gold "init" [
    ["pkg", "init"],  // So we don't accidentally use a /tmp/package.yaml.
  ]

  tester.gold "install" [
    ["exec", "main.toit"],
    ["pkg", "install", "--local", "pkg"],
    ["exec", "main.toit"],
    ["// Install with a prefix"],
    ["pkg", "install", "--local", "--prefix=prepkg", "pkg2"],
    ["exec", "main2.toit"],
    ["// Installing again yields an error."],
    ["pkg", "install", "--local", "pkg"],
    ["// Installing a package where the directory name is not the package name."],
    ["pkg", "install", "--local", "pkg3"],
    ["exec", "main3.toit"],
  ]

  tester.gold "install-non-existing" [
    ["pkg", "install", "--local", "non-existing"],
  ]

  tester.gold "install-file" [
    ["pkg", "install", "--local", "main.toit"],
  ]

  tester.gold "install-existing-prefix" [
    ["pkg", "install", "--local", "--prefix=pkg1", "pkg2"],
  ]

  tester.gold "install-non-existing-git" [
    ["pkg", "install", "some-pkg"],
  ]

  tester.gold "install-missing-yaml" [
    ["pkg", "install", "--local", "pkg-missing-yaml"],
  ]

  tester.gold "install-yaml-dir" [
    ["pkg", "install", "--local", "pkg-yaml-dir"],
  ]
