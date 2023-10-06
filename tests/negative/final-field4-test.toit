// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
// TEST_FLAGS: --force

call-lambda lambda/Lambda:
  lambda.call 499

call-block [block]:
  block.call 499

class A:
  field/int
  constructor:
    field = 499
    // We don't allow assignments to final fields in lambdas, as they
    // can survive the static part of a constructor.
    call-lambda:: field = it

  constructor.block-ok:
    field = 499
    call-block: field = it

  constructor.block-bad:
    field = 499
    block := (: field = it)
    call-block block

main:
  a := A
