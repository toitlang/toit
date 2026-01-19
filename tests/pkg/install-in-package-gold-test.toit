// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester --with-git-pkg-registry args: test it

test tester/GoldTester:
  tester.gold "00-test" [
    ["pkg", "init"],  // So we don't accidentally use a /tmp/package.yaml.
    ["pkg", "registry", "add", "--local", "test-reg", "registry"],
    ["pkg", "install", "foo"],
    ["pkg", "install", "bar"],
    ["package.lock"],
    ["package.yaml"]
  ]
