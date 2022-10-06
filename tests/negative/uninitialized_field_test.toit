// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

some_fun x:
call_block should_call/bool [block]:
  if should_call: block.call

call_lambda should_call/bool func/Lambda:
  if should_call: func.call

class A:
  field / any

class B:
  field / any

  constructor:
    if true:
      field = 499

  constructor.x:
    if true:
      print "not important"
    else:
      field = 499

  constructor.y:
    for i := 0; i < 0; i++:
      field = 42

  constructor.z:
    super

  constructor.foo:
    some_fun this

  constructor.gee:
    call_block false:
      field = 42

  constructor.lambda:
    call_lambda false::
      field = 42

  constructor.try_finally:
    try:
      field = 42
    finally:

  constructor.logical_and arg:
    arg and (if true: field = 499 else: field = 499)

  constructor.logical_or arg:
    arg or (if true: field = 499 else: field = 499)

main:
  A
  B
  B.x
  B.y
  B.z
  B.foo
  B.gee
  B.lambda
  B.try_finally
  B.logical_and true
  B.logical_or true
  unresolved
