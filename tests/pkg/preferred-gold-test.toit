// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  registry1 := "http://localhost:$tester.port$(AssetsBuilder.HTTP-REGISTRY-PREFIX)git-pkgs"
  registry2 := "registry"
  registry3 := "http://localhost:$tester.port$(AssetsBuilder.HTTP-REGISTRY-PREFIX)git-pkgs-newer-versions"

  tester.gold "10-init" [
    ["pkg", "init"],
  ]

  tester.gold "20-test" [
    ["// Add the git registry."],
    ["pkg", "registry", "add", "test-reg", registry1],
    ["pkg", "list"],
    ["pkg", "install", "pkg1"],
    ["// Should have version 3.1.2 for pkg3"],
    ["package.lock"],
    ["pkg", "registry", "add", "test-reg3", registry3],
    ["pkg", "registry", "add", "--local", "test-reg2", registry2],
    ["pkg", "list"],
    ["pkg", "install", "foo"],
    ["// Installing foo did not change the versions of existing packages."],
    ["package.lock"],
  ]

  // Remove the lock and package file.
  file.delete "$tester.working-dir/package.lock"
  file.delete "$tester.working-dir/package.yaml"

  tester.gold "30-new-versions" [
    ["pkg", "init"],
    ["pkg", "install", "pkg1"],
    ["// Now we have new versions (pkg2-2.4.3, pkg3-3.1.3)."],
    ["package.lock"],
  ]
