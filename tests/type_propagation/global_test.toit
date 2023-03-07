// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_simple

X ::= foo
Y := foo
Z := foo

test_simple:
  id X
  id Y
  Y = "hest"
  id Y
  id Z

foo:
  return 42

id x:
  return x

pick:
  return (random 100) < 50
