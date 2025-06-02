// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester --with-git-pkg-registry args: test it

test tester/GoldTester:
  tester.gold "install" [
    ["pkg", "init"],  // So we don't accidentally use a /tmp/package.yaml.
    ["pkg", "install", "pkg1"],
    ["package.lock"]
  ]
