// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test-break
  test-break-in-try
  test-continue
  test-nested
  test-store-below-target
  test-finally-store
  test-finally-unchanged
  test-two-trys
  test-sibling-finally
  test-continue-label
  test-continue-label-finally
  leak-preceding-state
  leak-break-vs-continue
  leak-two-targets
  leak-normal-exit
  leak-exception-path
  leak-return-vs-break
  leak-continue-label-vs-break
  leak-nested-trys
  leak-callee-try
  leak-callee-try-branches
  callee-finally-calls-block
  no-try-control

test-break:
  x/any := 42
  while true:
    invoke:
      x = "hest"
      break
  id x

test-break-in-try:
  x/any := 42
  while true:
    try:
      break
    finally:
  id x

test-continue:
  x/any := 42
  while true:
    invoke:
      x = "hest"
      if pick: continue
      x = 3.3
      break
  id x

test-nested:
  invoke:
    while true:
      invoke:
        break

test-store-below-target:
  x/any := 42
  invoke:
    while true:
      invoke:
        x = "hest"
        break
  id x

test-finally-store:
  x/any := 42
  while true:
    try:
      break
    finally:
      x = "hest"
  id x

test-finally-unchanged:
  x/any := 42
  while true:
    try:
      x = "hest"
      break
    finally:
  id x

test-two-trys:
  x/any := 42
  while true:
    try:
      try:
        break
      finally:
        x = "hest"
    finally:
      id x
      x = 3.3
  id x

test-sibling-finally:
  x/any := 42
  while true:
    invoke-try-both (: break) (: x = "hest")
  id x

test-continue-label:
  x/any := 42
  invoke-outer:
    invoke:
      x = "hest"
      continue.invoke-outer
  id x

test-continue-label-finally:
  x/any := 42
  invoke-outer:
    try:
      continue.invoke-outer
    finally:
      x = "hest"
  id x

// Expected at id: String_ only. The pre-call 42 cannot reach the target.
leak-preceding-state:
  x/any := 42
  while true:
    try:
      x = "hest"
      break
    finally:
  id x

// Expected at id: String_ only. The float is only on the continue path.
leak-break-vs-continue:
  x/any := 42
  while true:
    try:
      if pick:
        x = "hest"
        break
      x = 3.3
      continue
    finally:
    x = 7
  id x

// Expected: String_ at the first id and float at the second.
leak-two-targets:
  x/any := 42
  while true:
    outer-break := (: x = 3.3; break)
    while true:
      try:
        if pick:
          x = "hest"
          break
        outer-break.call
      finally:
    id x
    x = true
  id x

// Expected at id: String_ only. Normal exit assigns a float, and leaves.
leak-normal-exit:
  x/any := 42
  while true:
    try:
      if pick:
        x = "hest"
        break
      x = 3.3
    finally:
    return
  id x

// Expected at id: String_ only. The throw path stores a float.
leak-exception-path:
  x/any := 42
  while true:
    try:
      if pick:
        x = 3.3
        throw "fisk"
      x = "hest"
      break
    finally:
  id x

// Expected at id: String_ only. The return path stores a float.
leak-return-vs-break:
  x/any := 42
  while true:
    try:
      if pick:
        x = 3.3
        return
      x = "hest"
      break
    finally:
  id x

// Expected after invoke-outer: float|SmallInteger_ (not called), no String_.
leak-continue-label-vs-break:
  x/any := 42
  while true:
    invoke-outer:
      try:
        if pick:
          x = "hest"
          break
        x = 3.3
        continue.invoke-outer
      finally:
    id x
    return

// Expected at id: String_ only, through two trys.
leak-nested-trys:
  x/any := 42
  while true:
    try:
      try:
        if pick:
          x = 3.3
          continue
        x = "hest"
        break
      finally:
    finally:
  id x

// Expected at id: String_ only: the finally code cannot call the block.
leak-callee-try:
  x/any := 42
  while true:
    invoke-try:
      x = "hest"
      break
  id x

// Control without try: String_ only.
// Expected at id: String_ only: the float stays on the continue path.
leak-callee-try-branches:
  x/any := 42
  while true:
    invoke-try:
      if pick:
        x = 3.3
        continue
      x = "hest"
      break
  id x

// Expected at id: String_|SmallInteger_. The finally code may call the block,
// so we use the types at the call.
callee-finally-calls-block:
  x/any := 42
  while true:
    invoke-try-both (: break) (: x = "hest")
  id x

no-try-control:
  x/any := 42
  while true:
    invoke:
      if pick:
        x = 3.3
        continue
      x = "hest"
      break
  id x

id x:
  return x

pick:
  return (random 100) < 50

invoke [block]:
  block.call

invoke-outer [block]:
  block.call

invoke-try [block]:
  try:
    block.call
  finally:

invoke-try-both [a] [b]:
  try:
    a.call
  finally:
    b.call
