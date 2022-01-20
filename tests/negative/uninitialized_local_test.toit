// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

some_fun x: return x

use x:

call_block should_call/bool [block]:
  if should_call: block.call

call_lambda should_call/bool fun/Lambda:
  if should_call: fun.call

class A:
  constructor:
    local := ?
    super
    // Contrary to fields, locals might still be uninitialized after a
    //   super call.
    use local

main:
  local := ?
  use local

  local2 := ?
  if true:
    local2 = 499
  use local2

  local3 := ?
  if true:
    print "not important"
  else:
    local3 = 499
  use local3

  local4 := ?
  for i := 0; i < 0; i++:
    local4 = 42
  use local4

  local5 := ?
  call_block false:
    local5 = 42
  use local5

  local6 := ?
  call_lambda false::
    local6 = 42
  use local6

  local7 := ?
  try:
    local7 = 42
  finally:
  use local7

  local8 := ?
  (some_fun false) and (if true: local8 = 499 else: local8 = 499)
  use local8

  local9 := ?
  (some_fun true) and (if true: local9 = 42 else: local9 = 42)
  use local9

  while x := ?:
    x = 499

  unresolved
