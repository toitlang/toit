// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  evaluate:
    print "Hello"
    print "World"
  evaluate: print "Hello"; print "World"

  x := evaluate: "Fish"
  print x
  y := evaluate: "Funk"; "Fish"

  execute ["kurt", "klump"]

  z /int? := 42
  if z == 42: if z == 43: print "Kurt" else: print "Gerdt" else: print "Grod"
  w := if z: 17 else: 18
  print w

  if ww := foo: print ww
  if ww := foo 18: print ww
  if ww := foo 99: print ww

  if is_empty 42: print "lampe"

  if true: print "Hest"
  else: print "Not"

  n := evaluate:
    42
  print n

  try: 42 finally: 47

  expect_equals 41 (bar - 1)
  expect_equals 40 (bar - 2)
  expect_equals 39 (bar - 3)
  expect_equals -1 (bar -1)
  expect_equals -2 (bar -2)

execute list:
  list.do: print it

is_empty x:
  return x == 42

foo:
  return "los i offen"
foo x:
  print "kurt i boffen"; return x

evaluate [block]:
  return block.call

bar:
  return 42

bar x:
  return x
