// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester --with-default-registry args: test it

test tester/GoldTester:
  tester.gold "test" [
    ["// Should only contain the 'toit' registry."],
    ["pkg", "registry", "list"],
    ["pkg", "init"],
    ["pkg", "install", "github.com/toitware/toit-morse@1.0.6"],
  ]
