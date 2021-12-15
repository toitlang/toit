// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *
import core as core

main:
  local /int := 0
  expect_equals 0 local

  local2 /int? := null
  expect_null local2

  local3
    / int := 42
  expect_equals 42 local3

  local4
    /
    string
    := "str2"
  expect_equals "str2" local4

  local5 /string := ?
  local5 = "s"
  expect_equals "s" local5

  count := 0
  while local6/int? := (count > 0 ? null : 0):
    count++
  expect_equals 1 count

  count = 0
  for i/int := 0; i < 3; i++:
    count++
  expect_equals 3 count

  local7 / core.List := [1]
  expect_list_equals [1] local7
