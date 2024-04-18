// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import system

main args:
  toit-bin := args[0]
  version := pipe.backticks toit-bin "version"
  expect-equals "$system.vm-sdk-version\n" version

  dash-version := pipe.backticks toit-bin "--version"
  expect-equals "$system.vm-sdk-version\n" dash-version

  deprecated-short-version := pipe.backticks toit-bin "version" "--short"
  expect-equals "$system.vm-sdk-version\n" deprecated-short-version
