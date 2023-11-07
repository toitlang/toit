// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

some-fun x:
call-block should-call/bool [block]:
  if should-call: block.call

call-lambda should-call/bool fun/Lambda:
  if should-call: fun.call

test1 -> any:

test2:
  if true:
    return 499

test3:
  if true:
    print "not important"
  else:
    return 499

test4:
  for i := 0; i < 0; i++:
    return 499

test5:
  call-block false:
    return 499

test6 -> any:
  call-lambda false::
    continue.call-lambda 499

test7 arg -> any:
  arg and (return 499)

test8 arg -> any:
  arg or (return 499)

main:
  test1
  test2
  test3
  test4
  test5
  test6
  test7 true
  test8 true
  unresolved
