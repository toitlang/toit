// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  tester.gold "10-init" [
    ["pkg", "init"], // So we don't accidentally use a /tmp/package.yaml.
    ["pkg", "registry", "add", "test-reg", "--local", "registry-many-versions"],
    ["pkg", "list"],
  ]

  tester.gold "20-install-many" [
    ["pkg", "install", "many"],
    ["pkg", "install", "many@99"],
    ["pkg", "install", "many@1"],
    ["pkg", "install", "--prefix=foo", "many@1.0"],
    ["package.lock"],
    ["package.yaml"],
    ["pkg", "install", "--prefix=gee", "many@1"],
    ["package.lock"],
    ["package.yaml"],
    ["// These should fail as they are not valid versions."],
    ["pkg", "install", "--prefix=bad1", "many@"],
    ["pkg", "install", "--prefix=bad2", "many@not_a-version"],
  ]

  ["1", "1.1", "2", "2.3", "2.3.5"].do: | version/string |
    // Remove the lock and package file.
    file.delete "$tester.working-dir/package.lock"
    file.delete "$tester.working-dir/package.yaml"

    tester.gold "30-install-many@$version" [
      ["pkg", "init"], // So we don't accidentally use a /tmp/package.yaml.
      ["pkg", "install", "many@" + version],
      ["package.lock"],
      ["package.yaml"],
    ]
