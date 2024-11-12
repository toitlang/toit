// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test-simple
  test-invokes
  test-nesting
  test-catch
  test-too-few-arguments
  test-modify-outer
  test-modify-outer-nested
  test-recursion
  test-dead
  test-dependent

test-simple:
  x := 0
  1.repeat: x = x + 1
  id x  // Expect: int.

test-invokes:
  invoke: 42
  invoke "horse": it
  invoke 87: invoke it: it
  invoke true: invoke it: it

test-nesting:
  x := null
  invoke:
    if pick:
      x = 42
    else:
      x = "horse"
    id x  // Expect: smi|string|
  id x    // Expect: smi|string|null

  y := null
  invoke:
    invoke:
      if pick:
        y = true
      else:
        y = 3.7
      id y  // Expect: true|float
    id y    // Expect: true|float
  id y      // Expect: true|float

test-catch:
  z := null
  try:
    z = false
  finally:
    // Do nothing.

  x := null
  catch:
    x = 80
    throw "woops"
  id x  // Expect: smi|null

  y := null
  catch:
    y = "horse"
    maybe-throw
    y = 3.3
  id y  // Expect: string|float|null

test-too-few-arguments:
  catch:
    invoke: | x y | null  // This should throw.
    id 42                 // This should not be analyzed.

test-modify-outer:
  x/any := 42
  y/any := x
  2.repeat:
    y = x       // The updated type of 'x' should be visible.
    x = "hest"
  id x
  id y

test-modify-outer-nested:
  x/any := 42
  y/any := x
  2.repeat:
    3.repeat:
      y = x       // The updated type of 'x' should be visible.
      x = "hest"
    id x
    id y
  id x
  id y

test-recursion:
  recursive-null: 42
  recursive-null: false
  recursive-call: 87
  recursive-call: true
  recursive-a-null: 42
  recursive-a-null: "hest"
  recursive-a-call: 87
  recursive-a-call: "fisk"

test-dead:
  ignore: "hest"
  ignore: it
  ignore: | x y | 42

test-dependent:
  x := "hest"
  y := null
  invoke
      (: x = y )
      (: y = 42 )
  id x
  id y

recursive-null [block]:
  if pick: return recursive-null: null
  return block.call

recursive-call [block]:
  if pick: return recursive-call block
  return block.call

recursive-a-null [block]:
  if pick: return recursive-b-null: null
  return block.call

recursive-b-null [block]:
  return recursive-a-null: null

recursive-a-call [block]:
  if pick: return recursive-b-call block
  return block.call

recursive-b-call [block]:
  return recursive-a-call block

maybe-throw:
  if pick: throw "woops"

id x:
  return x

ignore [block]:
  // Do nothing.

pick:
  return (random 100) < 50

invoke [block]:
  return block.call

invoke [b1] [b2] -> none:
  b1.call
  b2.call

invoke x [block]:
  return block.call x
