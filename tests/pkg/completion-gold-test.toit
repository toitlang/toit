// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .gold-tester

main args:
  with-gold-tester --with-git-pkg-registry args: test it

test tester/GoldTester:
  tester.gold "10-unsynced" [
    ["// Completions must never go to the network:"],
    ["// an unsynced registry doesn't produce any candidates."],
    ["complete", "install", ""],
    ["// The registry names come from the local configuration and are still completed."],
    ["complete", "registry", "remove", ""],
  ]

  tester.gold "20-packages" [
    ["pkg", "sync"],
    ["// After a sync the registry is cached and produces candidates."],
    ["complete", "install", ""],
    ["// A '@' in the prefix completes the version part."],
    ["complete", "install", "pkg2@"],
    ["// With '--local' no candidates are produced; the shell falls back to file completion."],
    ["complete", "install", "--local", ""],
    ["// Option names are completed as well."],
    ["complete", "install", "--"],
  ]

  // The sync eagerly cached the parsed descriptions.
  expect (tester.has-descriptions-cache "git-pkgs")

  tester.corrupt-descriptions-cache "git-pkgs"
  tester.gold "25-corrupt-descriptions" [
    ["// A corrupt parsed-descriptions cache falls back to parsing the registry content."],
    ["complete", "install", ""],
  ]
  // The fallback repaired the cached parsed descriptions.
  expect (tester.has-descriptions-cache "git-pkgs")

  tester.gold "30-describe" [
    ["complete", "describe", ""],
    ["// The version argument completes the versions of the package given as first argument."],
    ["complete", "describe", "localhost:$tester.port/pkg/pkg2", ""],
    ["complete", "describe", "pkg2", ""],
  ]

  tester.gold "40-uninstall" [
    ["pkg", "init"],
    ["pkg", "install", "pkg1"],
    ["pkg", "install", "--prefix=other", "pkg3"],
    ["// Uninstall completes the prefixes of the installed packages."],
    ["complete", "uninstall", ""],
  ]

  tester.gold "50-misc" [
    ["// Subcommands are completed."],
    ["complete", ""],
    ["complete", "registry", ""],
    ["// Registry names for list and sync."],
    ["complete", "list", ""],
    ["complete", "registry", "sync", ""],
  ]
