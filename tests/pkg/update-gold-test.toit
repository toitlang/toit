// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  registry1 := "http://localhost:$tester.port$(AssetsBuilder.HTTP-REGISTRY-PREFIX)git-pkgs"
  registry2 := "http://localhost:$tester.port$(AssetsBuilder.HTTP-REGISTRY-PREFIX)git-pkgs-newer-versions"

  tester.gold "10-init" [
    ["pkg", "init"],
  ]

  tester.gold "20-test" [
    ["pkg", "registry", "add", "test-reg", registry1],
    ["pkg", "list"],
    ["pkg", "install", "pkg1"],
    ["pkg", "install", "pkg2"],
    ["// Should have version 3.1.2 for pkg3"],
    ["package.lock"],
    ["package.yaml"],
    ["pkg", "registry", "add", "test-reg2", registry2],
    ["pkg", "list"],
    ["pkg", "update"],
    ["// Now we have new versions (pkg2-2.4.3, pkg3-3.1.3)."],
    ["package.lock"],
    ["package.yaml"],
  ]
