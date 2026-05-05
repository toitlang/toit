// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file

import .gold-tester

main args:
  with-gold-tester args --with-git-pkg-registry: | tester/GoldTester |
    2.repeat: | iteration/int |
      test tester iteration

test tester/GoldTester iteration/int:
  if iteration == 1:
    // Second round remove the package and lock file.
    file.delete "$tester.working-dir/package.yaml"
    file.delete "$tester.working-dir/package.lock"

  tester.gold "test-$iteration" [
    ["pkg", "init"], // So we don't accidentally use a /tmp/package.yaml.
    ["// No package installed yet."],
    ["exec", "main.toit"],
    ["exec", "main2.toit"],
    ["// Install pkg4 for 'main.toit', creating/updating a lock file."],
    ["pkg", "install", "pkg4", "--prefix=pkg4_pre"],
    ["// main.toit should work now."],
    ["exec", "main.toit"],
    ["pkg", "install", "pkg1"],
    ["// main2.toit should also work now."],
    ["exec", "main2.toit"],
  ]
