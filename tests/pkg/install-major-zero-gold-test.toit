// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  tester.gold "10-install" [
    ["pkg", "init"], // So we don't accidentally use a /tmp/package.yaml.
    ["pkg", "registry", "add", "test-reg", "--local", "registry-zero"],
    ["// Without a version the newest 0.x is installed with a caret constraint."],
    ["pkg", "install", "zero"],
    ["package.yaml"],
    ["// An explicit minor is also written as a caret constraint."],
    ["pkg", "install", "--prefix=minor", "zero@0.1"],
    ["package.yaml"],
    ["// An explicit major 0 accepts all 0.x versions."],
    ["pkg", "install", "--prefix=major", "zero@0"],
    ["package.lock"],
    ["package.yaml"],
    ["pkg", "update"],
    ["package.yaml"],
  ]

  file.delete "$tester.working-dir/package.lock"
  file.delete "$tester.working-dir/package.yaml"

  tester.gold "20-major-update" [
    ["pkg", "init"],
    ["pkg", "install", "zero@0.0"],
    ["package.yaml"],
    ["pkg", "update", "--major", "zero@0"],
    ["package.lock"],
    ["package.yaml"],
  ]
