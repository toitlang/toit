// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import fs
import host.file

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  reg-path := fs.join tester.working-dir "registry-change"
  tester.gold "test" [
    ["pkg", "registry", "add", "--local", "test-reg", reg-path],
    ["pkg", "init"], // So we don't accidentally use a /tmp/package.yaml.
    ["pkg", "install", "foo@1.1"],
    ["pkg", "install", "bar"],
    ["// Even though the package foo@1.1 has as name 'other-name', it is installed as 'foo'."],
    ["pkg", "uninstall", "foo"],
    ["pkg", "uninstall", "bar"],
    ["pkg", "install", "foo"],
  ]
