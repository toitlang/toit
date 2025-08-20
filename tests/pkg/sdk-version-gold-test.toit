// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  tester.gold "10-setup" [
    ["pkg", "registry", "add", "--local", "test-reg", "registry"],
    ["pkg", "list", "--verbose"],
    ["pkg", "init"],
  ]


  tester.gold "20-v0.0.0" [
    ["pkg", "install", "foo", "--sdk-version", "v0.0.0"],
  ]

  tester.gold "30-no-constraint" [
    ["pkg", "install", "foo"],
    ["exec", "main.toit"],
    ["pkg", "uninstall", "foo"],
  ]

  tester.gold "40-v0.1.0" [
    ["pkg", "install", "foo", "--sdk-version", "v0.1.0"],
    ["exec", "main.toit"],
    ["// Update."],
    ["pkg", "update"],
    ["exec", "main.toit"],
  ]
