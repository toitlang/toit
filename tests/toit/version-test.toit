// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import system

import .utils

main args:
  toit-bin := ToitBin args
  version := toit-bin.backticks ["version"]
  expect-equals "$system.vm-sdk-version\n" version

  // The '--version' is special-cased. We are not allowed to the test-sdk override.
  dash-version := toit-bin.backticks --no-with-test-sdk ["--version"]
  expect-equals "$system.vm-sdk-version\n" dash-version

  deprecated-short-version := toit-bin.backticks ["version", "-o", "short"]
  expect-equals "$system.vm-sdk-version\n" deprecated-short-version
