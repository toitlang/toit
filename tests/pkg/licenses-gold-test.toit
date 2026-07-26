// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .gold-tester

import expect show *
import host.file

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  tester.gold "10-licenses" [
    ["pkg", "registry", "add", "test-registry", "--local", "registry"],
    ["pkg", "install", "remote"],
    ["pkg", "licenses", "--no-include-sdk", "--output=THIRD_PARTY_LICENSES"],
    ["cat", "THIRD_PARTY_LICENSES"],
  ]

  tester.gold "15-sdk-licenses" [
    ["pkg", "licenses", "--output=LICENSES_WITH_SDK"],
  ]
  with-sdk := (file.read-contents "$tester.working-dir/LICENSES_WITH_SDK").to-string
  expect (with-sdk.contains "Package: Toit SDK")
  expect (with-sdk.contains "Upstream-Name: Toit SDK")
  expect (with-sdk.contains "Files: third_party/dragonbox/*")

  tester.gold "20-missing-license" [
    ["pkg", "install", "missing"],
    ["pkg", "licenses", "--output=THIRD_PARTY_LICENSES"],
  ]

  file.write-contents
      --path="$tester.working-dir/licenses.yaml"
      """
      overrides:
        - url: localhost:$tester.port/pkg/missing
          version: 1.0.0
          path: overrides/missing.LICENSE
      """
  tester.gold "30-license-override" [
    ["pkg", "licenses", "--no-include-sdk", "--output=THIRD_PARTY_LICENSES"],
  ]
  with-override := (file.read-contents "$tester.working-dir/THIRD_PARTY_LICENSES").to-string
  expect (with-override.contains "License override: overrides/missing.LICENSE")
  expect (with-override.contains "Overridden package license.")

  file.write-contents
      --path="$tester.working-dir/licenses.yaml"
      """
      overrides:
        - url: localhost:$tester.port/pkg/missing
          version: 1.0.0
          path: overrides/missing.LICENSE
        - url: localhost:$tester.port/pkg/missing
          version: 2.0.0
          path: overrides/missing.LICENSE
      """
  tester.gold "40-unused-license-override" [
    ["pkg", "licenses", "--no-include-sdk", "--output=THIRD_PARTY_LICENSES"],
  ]

  file.write-contents
      --path="$tester.working-dir/licenses.yaml"
      """
      overrides:
        - url: localhost:$tester.port/pkg/missing
          version: 1.0.0
          path: overrides/missing.LICENSE
      """
  tester.gold "50-source-release" [
    ["pkg", "install", "copyleft"],
    ["pkg", "licenses", "--no-include-sdk", "--output=THIRD_PARTY_LICENSES"],
  ]

  file.write-contents
      --path="$tester.working-dir/licenses.yaml"
      """
      overrides:
        - url: localhost:$tester.port/pkg/missing
          version: 1.0.0
          path: overrides/missing.LICENSE
        - url: localhost:$tester.port/pkg/copyleft
          version: 1.0.0
          path: overrides/missing.LICENSE
      """
  tester.gold "60-source-release-override" [
    ["pkg", "licenses", "--no-include-sdk", "--output=THIRD_PARTY_LICENSES"],
  ]

  tester.gold "70-unrecognized-license" [
    ["pkg", "install", "unknown"],
    ["pkg", "licenses", "--no-include-sdk", "--output=THIRD_PARTY_LICENSES"],
  ]
