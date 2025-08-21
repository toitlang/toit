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
    ["pkg", "init"],
  ]

  tester.gold "20-test" [
    ["pkg", "install", "foo", "--sdk-version", "v0.1.10"],
    ["package.lock"],
    ["// A new 'install' doesn't change the lock file, even though",
      "// the sdk-version would permit an upgrade."],
    ["pkg", "install"],
    ["package.lock"],
  ]

  package-spec-path := "$tester.working-dir/package.yaml"
  old-contents := file.read-contents package-spec-path
  new-contents := old-contents.to-string + """
      environment:
        sdk: ^1.20.0
      """
  file.write-contents --path=package-spec-path new-contents

  tester.gold "30-test-with-new-constraint" [
    ["// We have updated the package.yaml."],
    ["package.yaml"],
    ["pkg", "install"],
    ["// Without --recompute nothing changed."],
    ["package.lock"],
    ["pkg", "install", "--recompute"],
    ["// The lockfile now has an 1.20 SDK constraint"],
    ["package.lock"],
  ]

