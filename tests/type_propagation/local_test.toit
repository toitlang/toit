// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_if
  test_if_else
  test_if_nested
  test_if_more_locals
  test_loop_simple
  test_loop_break
  test_loop_continue

test_if:
  x/any := 0
  if pick:
    x = "horse"
  id x

  x = 42
  id x

test_if_else:
  x/any := 0
  if pick:
    x = "horse"
  else:
    // Do nothing.
  id x

  if pick:
    x = "horse"
  else:
    x = true
  id x

test_if_nested:
  x := null
  if pick:
    if pick:
      x = 42
    else:
      x = 3.1
    id x
  else:
    if pick:
      x = true
    else:
      x = false
    id x
  id x  // Expect: smi|float|true|false.

test_if_more_locals:
  a := 0
  b := true
  c := 3.1
  d := null
  if pick: d = 87
  id a; id b; id c; id d
  if pick: b = false
  id a; id b; id c; id d

test_loop_simple:
  x := null
  while pick:
    x = 2
    id x
  id x  // Expect: smi|null.

test_loop_break:
  x := null
  while true:
    x = 2
    if pick: break
  id x  // Expect: smi.

  y := null
  while true:
    y = "horse"
    if pick: break
    if pick: y = 42
    id y
  id x // Expect: smi.
  id y // Expect: string.

test_loop_continue:
  x := null
  while pick:
    x = 2
    continue
    x = 8.7
  id x  // Expect: smi|null.

  y := null
  while pick:
    y = "horse"
    if pick: continue
    else: y = 42
  id x  // Expect: smi|null.
  id y  // Expect: smi|string|null.

id x:
  return x

pick:
  return (random 100) < 50
