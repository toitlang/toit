// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  tester.gold "search" [
    ["// Since there is no registry, we shouldn't find any package."],
    ["pkg", "search", "foo"],
    ["pkg", "registry", "add", "--local", "test-reg", "registry"],
    ["// Search should find packages now."],
    ["pkg", "search", "foo"],
    ["pkg", "search", "--verbose", "foo"],
    ["pkg", "search", "Foo-Desc"],
    ["pkg", "search", "bar"],
    ["pkg", "search", "sub"],
    ["// The gee package doesn't exist in this registry."],
    ["pkg", "search", "gee"],
    ["// Search also finds things in descriptions."],
    ["pkg", "search", "foo-desc"],
    ["pkg", "search", "bar-desc"],
    ["pkg", "search", "bAr-dEsc"],
    ["pkg", "search", "desc"],
    ["// Search also finds things in the URL."],
    ["pkg", "search", "pkg/foo"],
    ["pkg", "search", "pkg/bar"],
    ["pkg", "registry", "add", "--local", "test-reg2", "registry2"],
    ["// The new foo package has a higher version and shadows the other one."],
    ["pkg", "search", "foo"],
    ["// The gee package is now visible too."],
    ["pkg", "search", "gee"],
    ["// Works with bad case and subset"],
    ["pkg", "search", "Ee"],
    ["// Install doesn't work with subsets"],
    ["pkg", "install", "Ee"],
    ["// The bar and sub package didn't change"],
    ["pkg", "search", "bar"],
    ["pkg", "search", "sub"],
    ["// Find all packages:"],
    ["pkg", "search", ""],
  ]
