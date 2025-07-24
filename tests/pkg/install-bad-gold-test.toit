// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file

import .gold-tester

main args:
  with-gold-tester args --with-git-pkg-registry: test it

test tester/GoldTester:
  tester.gold "test" [
    ["pkg", "init"], // So we don't accidentally use a /tmp/package.yaml.
    ["// Prefix must be used with package name."],
    ["pkg", "install", "--prefix=foo"],
    ["// Path must be used with path."],
    ["pkg", "install", "--local"],
    ["// Prefix must be valid."],
    ["pkg", "install", "--prefix", "invalid prefix", "pkg2"],
  ]
