// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester --with-default-registry args: test it

test tester/GoldTester:
  git-registry-path := "http://localhost:$tester.port$(AssetsBuilder.HTTP-REGISTRY-PREFIX)git-pkgs"
  local-registry-path := "$tester.working-dir/registry"

  tester.gold "test" [
    ["// Should only contain the 'toit' registry."],
    ["pkg", "registry", "list"],
    ["pkg", "registry", "remove", "toit"],
    ["pkg", "registry", "list"],
    ["pkg", "registry", "add", "test-reg1", git-registry-path],
    ["pkg", "registry", "add", "--local", "test-reg2", local-registry-path],
    ["pkg", "registry", "list"],
    ["pkg", "registry", "remove", "non-existant"],
    ["pkg", "registry", "remove", "test-reg1"],
    ["pkg", "registry", "list"],
    ["pkg", "registry", "remove", "test-reg2"],
    ["pkg", "registry", "list"],
  ]
