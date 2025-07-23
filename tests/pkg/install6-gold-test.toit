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
    ["// Can't install two packages with '--local'"],
    ["pkg", "install", "--local", "pkg1", "pkg2"],
    ["// Can't install two packages with '--prefix'"],
    ["pkg", "install", "--prefix=foo", "pkg1", "pkg2"],
    ["// Can't install two packages with '--local' and '--prefix'"],
    ["pkg", "install", "--local", "--prefix=foo", "pkg1", "pkg2"],
    ["// Install both packages."],
    ["pkg", "install", "pkg1", "pkg2"],
    ["exec", "test.toit"],
  ]
