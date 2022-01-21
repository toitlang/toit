// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  field := (: 499)

  constructor:
    block := (: 499)
    field = block
    field += block

  foo:
    field = (: 499)
    this.field = (: 499)

global := (: 499)

main:
  block := (: 499)
  x := block[10]
  x = block as string
  y := null
  y.foo = block
  block.foo = 42
  block[10] = 42
  y[10] = block
  block[10] += 4

  block2 := (: 42)
  block = block2
  block += block2

  local := if true:
    tmp := (: 499)
    tmp
  if true:
    tmp := (: 499)
    tmp
  else:
    tmp := (: 42)
    tmp

  if block:
    print "ok"

  if true:
    block

  if true:
    "foo"
    null
  else:
    "bar"
    block


  while xx := block:
    "while"

  for xx := block; false; false:
    "for"

  is_result := block is Lambda
  cast_result := block as any

  binary :=  block + 3
  binary = 3 + block

  comp := block < 3
  comp = 3 < block
  comp = 3 < block < 10
  comp = block < 3 < 10
  comp = 3 < 10 < block

  logical := block or 3
  logical = 3 or block
  logical = block and true or false

  not := not block
  minus := -block

  "$block"
  "$block $block"

  [block, block]
  {block, block}
  {block : block}
