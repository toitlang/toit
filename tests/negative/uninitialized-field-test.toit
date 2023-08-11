// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

some-fun x:
call-block should-call/bool [block]:
  if should-call: block.call

call-lambda should-call/bool fun/Lambda:
  if should-call: fun.call

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
    some-fun this

  constructor.gee:
    call-block false:
      field = 42

  constructor.lambda:
    call-lambda false::
      field = 42

  constructor.try-finally:
    try:
      field = 42
    finally:

  constructor.logical-and arg:
    arg and (if true: field = 499 else: field = 499)

  constructor.logical-or arg:
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
  B.try-finally
  B.logical-and true
  B.logical-or true
  unresolved
