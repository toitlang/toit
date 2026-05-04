// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester --with-git-pkg-registry args: test it

test tester/GoldTester:
  tester.gold "test" [
    ["// No package installed yet."],
    ["exec", "main.toit"],
    ["// Just 'install' doesn't add the missing dependencies."],
    ["pkg", "install"],
    ["package.lock"],
    ["// With '--recompute' we get the missing dependencies."],
    ["pkg", "install", "--recompute"],
    ["// Should work now."],
    ["exec", "main.toit"],
  ]
