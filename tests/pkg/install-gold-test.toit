// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import expect show *
import host.directory
import host.file
import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  tester.gold "10-install" [
    ["pkg", "registry", "add", "--local", "test-reg", "registry"],
    ["pkg", "install", "foo"],
    ["pkg", "install", "bar"],
    ["pkg", "install", "--local", "target"],
    ["exec", "main.toit"],
  ]

  foo-version := "1.2.3"
  foo-path := tester.package-cache-path "pkg/foo" --version=foo-version
  expect (file.is-directory foo-path)
  directory.rmdir --recursive --force foo-path

  bar-version := "2.0.1"
  bar-path := tester.package-cache-path "pkg/bar" --version=bar-version
  expect (file.is-directory bar-path)
  directory.rmdir --recursive --force bar-path

  tester.gold "20-fail" [
    ["exec", "main.toit"],
  ]

  tester.gold "30-install" [
    ["pkg", "install"],
  ]

  tester.gold "40-exec" [
    ["exec", "main.toit"],
  ]

  // Ensure that the directories are back.
  // We don't guarantee that the directories are the same as before.

  foo-path = tester.package-cache-path "pkg/foo" --version=foo-version
  expect (file.is-directory foo-path)

  bar-path = tester.package-cache-path "pkg/bar" --version=bar-version
  expect (file.is-directory bar-path)
