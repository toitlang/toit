// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester --with-git-pkg-registry args: test it

test tester/GoldTester:
  tester.gold "list" [["pkg", "list", "list-registry"]]
  tester.gold "list-verbose" [["pkg", "list", "--verbose", "list-registry"]]
  tester.gold "bad" [["pkg", "list", "bad-registry"]]
  tester.gold "bad2" [["pkg", "list", "bad-registry2"]]
  tester.gold "bad3" [["pkg", "list", "bad-registry3"]]
  tester.gold "bad4" [["pkg", "list", "bad-registry4"]]
  tester.gold "bad5" [["pkg", "list", "bad-registry5"]]
