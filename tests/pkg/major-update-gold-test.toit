// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  registry1 := "http://localhost:$tester.port$(AssetsBuilder.HTTP-REGISTRY-PREFIX)git-pkgs"
  registry2 := "http://localhost:$tester.port$(AssetsBuilder.HTTP-REGISTRY-PREFIX)git-pkgs-newer-versions"

  tester.gold "10-test" [
    ["pkg", "init"],
    ["pkg", "registry", "add", "test-reg", registry1],
    ["pkg", "install", "pkg1"],
    ["pkg", "install", "pkg2@1"],
    ["// The direct dependency starts on major 1 while pkg1 still needs major 2."],
    ["package.lock"],
    ["package.yaml"],
    ["pkg", "registry", "add", "test-reg2", registry2],
    ["pkg", "update", "--major", "pkg2@2"],
    ["// An explicit major selects its newest solvable version."],
    ["package.lock"],
    ["package.yaml"],
    ["pkg", "update", "--major", "pkg2"],
    ["// An unqualified major update selects the newest solvable major."],
    ["package.lock"],
    ["package.yaml"],
    ["pkg", "update", "--major"],
    ["pkg", "update", "--major", "pkg2@v2"],
  ]
