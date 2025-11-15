// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  abs-registry-path := "$tester.working-dir/registry"
  tester.gold "registry" [
    ["// In a fresh configuration we don't expect to see any registry."],
    ["pkg", "registry", "list"],
    ["pkg", "registry", "add", "--local", "test-reg", abs-registry-path],
    ["pkg", "registry", "list"],
    ["pkg", "list"],
    ["// Note that the second registry is added with a relative path",
      "// But that the list below shows it with an absolute path"],
    ["pkg", "registry", "add", "--local", "test-reg2", "registry2"],
    ["pkg", "registry", "list"],
    ["pkg", "list"],
    ["pkg", "registry", "add", "--local", "bad-registry", "bad_registry"],
    ["// It's OK to add the same registry with the same name again"],
    ["pkg", "registry", "add", "--local", "test-reg", "registry"],
    ["// It's an error to add a registry with an existing name but a different path"],
    ["pkg", "registry", "add", "--local", "test-reg2", "registry2"]
  ]
