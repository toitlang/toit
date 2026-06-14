// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  reg-with-hidden-path := "$tester.working-dir/reg-with-hidden"
  tester.gold "registry" [
    ["pkg", "registry", "add", "--local", "test-reg", reg-with-hidden-path],
    ["// Should be empty and ignore the hidden folder."],
    ["pkg", "list"],
  ]
