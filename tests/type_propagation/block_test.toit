// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_simple
  test_invokes
  test_nesting
  test_catch
  test_too_few_arguments
  test_modify_outer
  test_modify_outer_nested
  test_recursion

test_simple:
  x := 0
  1.repeat: x = x + 1
  id x  // Expect: int.

test_invokes:
  invoke: 42
  invoke "horse": it
  invoke 87: invoke it: it
  invoke true: invoke it: it

test_nesting:
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

test_catch:
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
    maybe_throw
    y = 3.3
  id y  // Expect: string|float|null

test_too_few_arguments:
  catch:
    invoke: | x y | null  // This should throw.
    id 42                 // This should not be analyzed.

test_modify_outer:
  x/any := 42
  y/any := x
  2.repeat:
    y = x       // The updated type of 'x' should be visible.
    x = "hest"
  id x
  id y

test_modify_outer_nested:
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

test_recursion:
  recursive_null: 42
  recursive_null: false
  recursive_call: 87
  recursive_call: true
  recursive_a_null: 42
  recursive_a_null: "hest"
  recursive_a_call: 87
  recursive_a_call: "fisk"

recursive_null [block]:
  if pick: return recursive_null: null
  return block.call

recursive_call [block]:
  if pick: return recursive_call block
  return block.call

recursive_a_null [block]:
  if pick: return recursive_b_null: null
  return block.call

recursive_b_null [block]:
  return recursive_a_null: null

recursive_a_call [block]:
  if pick: return recursive_b_call block
  return block.call

recursive_b_call [block]:
  return recursive_a_call block

maybe_throw:
  if pick: throw "woops"

id x:
  return x

pick:
  return (random 100) < 50

invoke [block]:
  return block.call

invoke x [block]:
  return block.call x
