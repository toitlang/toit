// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import system

import .utils

main args:
  toit-exe := ToitExecutable args
  version := toit-exe.backticks ["version"]
  expect-equals "$system.vm-sdk-version\n" version

  // The '--version' flag is special-cased in the 'toit' executable.
  // It must be the first argument. As such, we can have any '--sdk-version'
  // before it. The '--no-with-test-sdk' make sure we don't any additional
  // options when calling the binary.
  dash-version := toit-exe.backticks --no-with-test-sdk ["--version"]
  expect-equals "$system.vm-sdk-version\n" dash-version

  deprecated-short-version := toit-exe.backticks ["version", "-o", "short"]
  expect-equals "$system.vm-sdk-version\n" deprecated-short-version
