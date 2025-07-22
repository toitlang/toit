// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import fs
import .gold-tester

main args:
  with-gold-tester --with-git-pkg-registry args: test it

test tester/GoldTester:
  tester.gold "00-install" [
    ["pkg", "init"],  // So we don't accidentally use a /tmp/package.yaml.
    ["pkg", "install", "pkg1"],
    ["package.lock"]
  ]

  tester.gold "10-git package search" [
    ["// Execution should fail, as the package is not installed yet"],
    ["exec", "main.toit"],
    ["// Install packages from the registry"],
    ["pkg", "registry", "add", "--local", "test-reg", "registry"],
    ["pkg", "install", "foo"],
    ["pkg", "install", "bar"],
    ["// Execution should succeed now"],
    ["exec", "main.toit"],
    ["// Execution should fail, as the prefixes are not yet known"],
    ["exec", "main2.toit"],
    ["pkg", "install", "--prefix=pre1", "foo"],
    ["pkg", "install", "--prefix=pre2", "bar"],
    ["// Execution should succeed now"],
    ["exec", "main2.toit"]
  ]

  tester.gold "20-bad-pkg search" [
    ["// Add a registry, so that we have conflicts"],
    ["pkg", "registry", "add", "--local", "test-reg2", "registry2"],
    ["pkg", "search", "--verbose", "foo"],
    ["pkg", "install", "--prefix=pre3", "foo"]
  ]

  tester.gold "30-package.lock" [
    ["package.lock"]
  ]

  readme-path := fs.join tester.working-dir ".packages" "README.md"
  expect (file.is-file readme-path)

  foo-file :=
