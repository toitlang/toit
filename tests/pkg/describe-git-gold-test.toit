// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import host.directory

import .gold-tester

main args:
  with-gold-tester args: test it

test tester/GoldTester:
  tester.gold "morse" [
    ["pkg", "describe", "github.com/toitware/toit-morse", "v1.0.6"],
  ]

  tester.gold "morse-upper" [
    ["pkg", "describe", "githUb.com/toitware/toit-MoRse", "v1.0.6"],
  ]

  tester.gold "https-morse" [
    ["pkg", "describe", "https://github.com/toitware/toit-morse", "v1.0.6"],
  ]

  tester.gold "https-morse-dot-git" [
    ["pkg", "describe", "https://github.com/toitware/toit-morse.git", "v1.0.6"],
  ]

  tester.gold "not-found" [
    ["pkg", "describe", "https://toit.io/testing/not_exist", "v1.0.0"],
    ["pkg", "describe", "github.com/toitware/toit-morse", "v99.0.0"],
  ]

  tester.gold "bad-version" [
    ["pkg", "describe", "https://github.com/toitware/toit-morse", "1.0.0"],
    ["pkg", "describe", "https://github.com/toitware/toit-morse", "bad-version"],
    ["pkg", "describe", "https://github.com/toitware/toit-morse", "vbad-version"],
    ["pkg", "describe", "https://github.com/toitware/toit-ignore", "1.0"],
    ["pkg", "describe", "https://github.com/toitware/toit-ignore", "v1.0"],
  ]

  tester.gold "local-dep" [
    ["pkg", "describe", "localhost:$tester.port/pkg/local-path", "v1.0.0"],
    ["pkg", "describe", "--allow-local-deps", "localhost:$tester.port/pkg/local-path", "v1.0.0"],
  ]

  out-dir := "$tester.working-dir/out"
  desc-path := "$out-dir/packages/github.com/toitware/toit-morse/1.0.6/desc.yaml"
  tester.gold "write" [
    ["pkg", "describe", ".", "--out-dir=foo"],
    ["pkg", "describe", "--out-dir=foo"],
    ["pkg", "describe", "https://github.com/toitware/toit-morse", "v1.0.6", "--out-dir=$out-dir"],
    ["cat", desc-path],
  ]
