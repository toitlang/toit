// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

some-fun x: return x

use x:

call-block should-call/bool [block]:
  if should-call: block.call

call-lambda should-call/bool fun/Lambda:
  if should-call: fun.call

main:
  local ::= ?
  local = 499
  local = 42

  local2 ::= ?
  if true:
    local2 = 499
  local2 = 42
  use local2

  local3 ::= ?
  if true:
    print "not important"
  else:
    local3 = 499
  use local3

  local4 ::= ?
  for i := 0; i < 0; i++:
    local4 = 42
    use local4

  local5 ::= ?
  for i := 0; i < 0; local5 = 0:

  local6 ::= ?
  call-block false:
    local6 = 42
  use local6

  local7 ::= ?
  call-lambda false::
    local7 = 42
  use local7

  local8 ::= ?
  for i := 0; i < 2; local8 = 42:
    i++

  unresolved
