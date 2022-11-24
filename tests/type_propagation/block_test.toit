// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_simple
  test_invokes

test_simple:
  x := 0
  1.repeat: x = x + 1
  id x  // Expect: int.

test_invokes:
  invoke: 42
  invoke "horse": it
  invoke 87: invoke it: it
  invoke true: invoke it: it

id x:
  return x

invoke [block]:
  return block.call

invoke x [block]:
  return block.call x
