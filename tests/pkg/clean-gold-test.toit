// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.directory
import host.file

import .gold-tester

main args:
  with-gold-tester args --with-git-pkg-registry: test it

test tester/GoldTester:
  tester.run [
    ["pkg", "init"],
    ["pkg", "install", "pkg1"],
    ["pkg", "install", "pkg2"],
    ["package.lock"],
  ]

  pkg1-path := tester.package-cache-path "pkg1" --version="1.0.0"
  pkg2-path := tester.package-cache-path "pkg2" --version="2.4.2"
  pkg3-path := tester.package-cache-path "pkg3" --version="3.1.2"

  expect (file.is-directory pkg1-path)
  expect (file.is-directory pkg2-path)
  expect (file.is-directory pkg3-path)

  tester.gold "10-clean1" [
    ["pkg", "uninstall", "pkg1"],
    ["pkg", "clean"],
    ["contents.json"],
    ["package.lock"],
  ]

  expect-not (file.is-directory pkg1-path)
  expect (file.is-directory pkg2-path)
  expect (file.is-directory pkg3-path)

  tester.gold "20-clean2" [
    ["pkg", "uninstall", "pkg2"],
    ["pkg", "clean"],
    ["contents.json"],
    ["package.lock"],
  ]
