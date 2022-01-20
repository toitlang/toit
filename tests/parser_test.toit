// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  evaluate:
    debug "Hello"
    debug "World"
  evaluate: debug "Hello"; debug "World"

  x := evaluate: "Fish"
  debug x
  y := evaluate: "Funk"; "Fish"

  execute ["kurt", "klump"]

  z /int? := 42
  if z == 42: if z == 43: debug "Kurt" else: debug "Gerdt" else: debug "Grod"
  w := if z: 17 else: 18
  debug w

  if ww := foo: debug ww
  if ww := foo 18: debug ww
  if ww := foo 99: debug ww

  if is_empty 42: debug "lampe"

  if true: debug "Hest"
  else: debug "Not"

  n := evaluate:
    42
  debug n

  try: 42 finally: 47

  expect_equals 41 (bar - 1)
  expect_equals 40 (bar - 2)
  expect_equals 39 (bar - 3)
  expect_equals -1 (bar -1)
  expect_equals -2 (bar -2)

execute list:
  list.do: debug it

is_empty x:
  return x == 42

foo:
  return "los i offen"
foo x:
  debug "kurt i boffen"; return x

evaluate [block]:
  return block.call

bar:
  return 42

bar x:
  return x
