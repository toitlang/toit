// Copyright (C) 2020 Toitware ApS. All rights reserved.

some_fun x:
call_block should_call/bool [block]:
  if should_call: block.call

call_lambda should_call/bool fun/Lambda:
  if should_call: fun.call

class B:
  field / any

  constructor:
    some_fun field
    field = 499

  constructor.x:
    if true:
      some_fun field
      field = 42
    else:
      field = 499

  constructor.y:
    for i := 0; i < 0; i++:
      some_fun field
    field = 499

  constructor.z:
    field++

  constructor.foo:
    some_fun this

  constructor.gee arg arg2:
    if arg:
      if arg2:
        field = 0
      field++
    else:
      field = -1

  constructor.block:
    call_block true:
      field
    field = 499

  constructor.block2:
    call_block true:
      field
    field = 499

  constructor.lambda:
    call_lambda true::
      field
    field = 499

  constructor.lambda2:
    call_lambda true::
      field
    field = 499

  constructor.try_finally:
    try:
      field = 499
    finally:
      field
    field = 42

  constructor.for_update:
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
  B.try_finally
  B.for_update
  unresolved
