// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

some-fun x:
call-block should-call/bool [block]:
  if should-call: block.call

call-lambda should-call/bool fun/Lambda:
  if should-call: fun.call

class B:
  field / any

  constructor:
    some-fun field
    field = 499

  constructor.x:
    if true:
      some-fun field
      field = 42
    else:
      field = 499

  constructor.y:
    for i := 0; i < 0; i++:
      some-fun field
    field = 499

  constructor.z:
    field++

  constructor.foo:
    some-fun this

  constructor.gee arg arg2:
    if arg:
      if arg2:
        field = 0
      field++
    else:
      field = -1

  constructor.block:
    call-block true:
      field
    field = 499

  constructor.block2:
    call-block true:
      field
    field = 499

  constructor.lambda:
    call-lambda true::
      field
    field = 499

  constructor.lambda2:
    call-lambda true::
      field
    field = 499

  constructor.try-finally:
    try:
      field = 499
    finally:
      field
    field = 42

  constructor.for-update:
    for i := 0; i < 2; i < field:
      if i == 0: continue
      field = 499
    field = 42

main:
  B
  B.x
  B.y
  B.z
  B.foo
  B.gee true false
  B.block
  B.block2
  B.lambda
  B.lambda2
  B.try-finally
  B.for-update
  unresolved
