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
    ["pkg", "registry", "add", "--local", "test-reg2", "registry-ambiguous"],
    ["// Ambiguous pkg1"],
    ["pkg", "install", "pkg1"],
    ["// Disambiguate by giving full URL."],
    ["pkg", "install", "localhost:$tester.port/pkg/pkg1"],
    ["// Ambiguous pkg2"],
    ["pkg", "search", "--verbose", "pkg2"],
    ["// Disambiguate by giving full URL even though that's the suffix of the longer one."],
    ["pkg", "install", "localhost:$tester.port/pkg/pkg2"],
    ["// Ambiguous 'ambiguous'"],
    ["pkg", "search", "--verbose", "ambiguous"],
    ["// Need to add more segments to disambiguate."],
    ["pkg", "install", "b/c/d/ambiguous"],
    ["// Will still yield an error (because we don't have the package),",
      "// but it's a different one"],
    ["pkg", "install", "a/b/c/d/ambiguous"]
  ]
