// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Tests that the types of locals are tracked correctly through non-local
// branches and returns. Every test returns what a local holds at runtime and
// the checks are done with 'is', which the optimizer folds using the propagated
// types. Wrong types make the checks fail - and they make the interpreter fail
// when it is built with TOIT_CHECK_PROPAGATED_TYPES.

run [block]: block.call
outer [block]: block.call
run2 [a] [b]:
  try:
    a.call
  finally:
    b.call

// Branch out of a nested block to a target that is itself in a block;
// the store is to a level below the target level.
store-below-target:
  x/any := 42
  run:
    while true:
      run:
        x = "hest"
        break
  return x

// continue.label from a nested block: returns from level-1 block.
continue-label:
  x/any := 42
  outer:
    run:
      x = "hest"
      continue.outer
  return x

// Finally stores before branch reaches target.
finally-store:
  x/any := 42
  while true:
    try:
      break
    finally:
      x = "hest"
  return x

// Sibling block runs from a callee's finally after the branch.
sibling-finally:
  x/any := 42
  while true:
    run2 (: break) (: x = "hest")
  return x

// continue.label crossing a try whose finally stores.
continue-label-finally:
  x/any := 42
  outer:
    try:
      continue.outer
    finally:
      x = "hest"
  return x

// Branch crossing two nested trys.
two-trys:
  x/any := 42
  while true:
    try:
      try:
        break
      finally:
        x = "hest"
    finally:
      x = x is string ? 3.5 : x
  return x

// Branch precision: only the int should be seen.
precise:
  x/any := 42
  while true:
    try:
      break
    finally:
  return x

// Loop inside the finally code before the branch goes on.
finally-loop:
  x/any := 42
  while true:
    try:
      break
    finally:
      3.repeat: x = it == 2 ? "hest" : 3.5
  return x

// A nested block in the finally code stores, seen at the target in a block.
finally-block-below-target:
  x/any := 42
  run:
    while true:
      try:
        run: break
      finally:
        run: x = "hest"
  return x

// Sibling reached through another method's try; indirect call.
indirect [a] [b]:
  try:
    run2 a b
  finally:
    b.call
sibling-indirect:
  x/any := 42
  while true:
    indirect (: break) (: x = "hest")
  return x

// Exception stops in a callee; break elsewhere; store survives.
catch-then-branch:
  x/any := 42
  while true:
    catch:
      run:
        x = "hest"
        throw "fisk"
    break
  return x

// The finally changes the local on one iteration only. Continue crossing.
continue-through-finally:
  x/any := 42
  count := 0
  while count < 3:
    count++
    try:
      if count == 1: continue
    finally:
      x = count == 1 ? "hest" : x
    x = x is string ? 3.5 : x
  return x

// A break in the finally code ends the unwinding of the outer branch.
break-in-finally:
  x/any := 42
  outer:
    while true:
      try:
        continue.outer
      finally:
        x = "hest"
        break
    x = x is string ? 3.5 : x
  return x

// A continue in the finally relinks the try; the normal path must run on.
continue-in-finally:
  x/any := 42
  count := 0
  while count < 3:
    count++
    try:
      if count == 1: break
      x = "hest"
    finally:
      if count == 1: continue
    x = x is string ? 3.5 : x
  return x

// Non-local branch inside a finally that is itself part of an unwinding.
nested-finally-branch:
  x/any := 42
  outer:
    while true:
      try:
        continue.outer
      finally:
        while true:
          try:
            run: break
          finally:
            x = "hest"
    x = 7
  return x

// Break out of a nested finally, leaving the outer unwinding running.
break-keeps-outer-unwinding:
  x/any := 42
  outer:
    try:
      continue.outer
    finally:
      while true:
        try:
          break
        finally:
          x = "hest"
  return x

// A finally in a callee stops the unwinding, so the store must be visible.
stop-in-callee-finally:
  x/any := 42
  while true:
    stop-unwinding:
      x = "hest"
      break
    return x
  return 7

stop-unwinding [block]:
  try:
    block.call
  finally:
    return

// The sibling runs from a finally through a block in another method.
sibling-through-middle:
  x/any := 42
  while true:
    middle (: break) (: x = "hest")
  return x

middle [a] [b]:
  run2 a: b.call

// The sibling runs from a method called by the finally code.
sibling-through-call:
  x/any := 42
  while true:
    call-in-finally (: break) (: x = "hest")
  return x

call-in-finally [a] [b]:
  try:
    a.call
  finally:
    run b

// The callee's finally only runs the sibling when in a nested finally.
sibling-nested-finally:
  x/any := 42
  while true:
    nested-finally (: break) (: x = "hest")
  return x

nested-finally [a] [b]:
  try:
    a.call
  finally:
    try:
      null
    finally:
      null
    b.call

main:
  expect (store-below-target is string)
  expect (continue-label is string)
  expect (finally-store is string)
  expect (sibling-finally is string)
  expect (continue-label-finally is string)
  expect (two-trys is float)
  expect (precise is int)
  expect (finally-loop is string)
  expect (finally-block-below-target is string)
  expect (sibling-indirect is string)
  expect (catch-then-branch is string)
  expect (continue-through-finally is float)
  expect (break-in-finally is float)
  expect (continue-in-finally is float)
  expect (nested-finally-branch is string)
  expect (break-keeps-outer-unwinding is string)
  expect (stop-in-callee-finally is string)
  expect (sibling-through-middle is string)
  expect (sibling-through-call is string)
  expect (sibling-nested-finally is string)
