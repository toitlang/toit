// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_simple
  test_invokes
  test_nesting
  test_catch

test_simple:
  x := 0
  1.repeat: x = x + 1
  id x  // Expect: int.

test_invokes:
  invoke: 42
  invoke "horse": it
  invoke 87: invoke it: it
  invoke true: invoke it: it

// TODO(kasper): This currently does not work as expected.
// This is reflected by the gold file :(
test_nesting:
  x := null
  invoke:
    if pick:
      x = 42
    else:
      x = "horse"
    id x  // Expect: smi|string
  id x    // Expect: smi|string

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
  id x

  y := null
  catch:
    y = "horse"
    maybe_throw
    y = 3.3
  id y

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
