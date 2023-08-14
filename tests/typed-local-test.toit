// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import core as core

main:
  local /int := 0
  expect-equals 0 local

  local2 /int? := null
  expect-null local2

  local3
    / int := 42
  expect-equals 42 local3

  local4
    /
    string
    := "str2"
  expect-equals "str2" local4

  local5 /string := ?
  local5 = "s"
  expect-equals "s" local5

  count := 0
  while local6/int? := (count > 0 ? null : 0):
    count++
  expect-equals 1 count

  count = 0
  for i/int := 0; i < 3; i++:
    count++
  expect-equals 3 count

  local7 / core.List := [1]
  expect-list-equals [1] local7
