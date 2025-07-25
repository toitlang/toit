// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  registry-url := "http://localhost:$tester.port/registry/git-pkgs"
  tester.gold "registry" [
    ["// Add git registry."],
    ["pkg", "registry", "add", "test-reg", registry-url],
    ["pkg", "init"],
    ["pkg", "install", "pkg1"],
    ["exec", "main.toit"],
    ["// Adding the registry again has no effect."],
    ["pkg", "registry", "add", "test-reg", registry-url],
    ["// Adding the registry with a different value doesn't work."],
    ["pkg", "registry", "add", "test-reg", "different-url"],
  ]
