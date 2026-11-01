// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Regression tests for the type propagator. They were found by generating
// random programs and reduced by hand, so they are deliberately odd: the
// shape of the code is what matters, including the empty try-blocks and the
// blocks that do nothing. Please don't tidy them up.
//
// All of these used to go wrong in the same way: the propagator didn't see
// all the types that could reach a piece of code, or concluded that the code
// couldn't be reached at all. As a result, the optimizer removed code that
// runs and folded type checks incorrectly, and the interpreter fails on them
// when it is built with TOIT_CHECK_PROPAGATED_TYPES.
//
// Each test records what it sees through 'observe', driven by a fixed script
// for 'pick' that takes it down the path that used to go wrong.

script_/string := ""
next_/int := 0
budget_/int := 0
tick_/int := 0
observed_/List := []

// Returns the next value from the script; 'T' is true and anything else,
// including running out of script, is false. The script is not constant
// as far as the propagator knows, so it must consider both outcomes.
pick -> bool:
  if next_ >= script_.size: return false
  return script_[next_++] == 'T'

// Used as the condition of loops to make sure they terminate.
budget -> bool:
  budget_--
  return budget_ > 0

observe value/any -> none:
  if value is string: observed_.add "string"
  else if value is int: observed_.add "int"
  else if value is float: observed_.add "float"
  else if value == null: observed_.add "null"
  else if value == true: observed_.add "true"
  else if value == false: observed_.add "false"
  else: observed_.add "unknown"

run [block]:
  block.call

// The block runs in a try-block.
two [a] [b]:
  try:
    a.call
    b.call
  finally:
    tick_++

// The second block runs in finally code.
two-finally [a] [b]:
  try:
    a.call
  finally:
    b.call

check expected/List script/string --budget/int [test]:
  script_ = script
  next_ = 0
  budget_ = budget
  observed_ = []
  catch: test.call
  expect-list-equals expected observed_

// The back edge of the loop adds a type to a local at the loop header. The
// code after the loop has already been reached from the 'break' and the
// local in a block scope is shared between them. The types seen at the loop
// exit must grow, even though they are merged into a scope that shares the
// stack with the loop header.
test-loop-exit-sees-back-edge:
  x/any := "s"
  y/any := true
  try:
    if pick:
      while budget:
        if pick:
          x = 1
        if pick: break
        y = "s"
    try:
      try:
      finally: | t e |
        try:
        finally:
    finally:
      if y is float: observe y
      try:
      finally: | t e |
        observe y
  finally: | t e |

// The 'continue' leaves two blocks and a call to a method with a try-block.
// The code after the outer try-block is reachable without going through
// the loop at all.
test-continue-out-of-catch:
  x/any := true
  try:
    catch:
      if pick:
      else:
        while budget:
          catch:
            a := :
              c := :
              d := :
              two c d
            b := :
              if pick: continue
            two a b
  finally:
  observe x

// The block has a loop that branches out of a try-block in another method.
// The code that follows has to be analyzed as being reachable.
test-continue-then-later-code:
  x/any := null
  try:
    block := :
      while budget:
        a := :
          try:
          finally: | t e |
        b := :
          if pick: continue
        two a b
    if pick: block.call
  finally: | t e |
  try:
    a := :
      try:
      finally:
    b := :
    two a b
    c := :
      e := :
        observe x
      f := :
      two e f
    d := :
      try:
      finally:
    two c d
  finally:

// Non-local branches out of nested try-blocks and finally code, followed
// by a finally block with parameters.
test-finally-parameter-after-branches:
  run:
    try:
      a := :
      b := :
        while budget:
          try:
            try:
              block := :
                if pick: continue
              if pick: block.call
            finally:
          finally: | t e |
            if pick: break
      two-finally a b
    finally:
  try:
  finally:
    try:
      try:
      finally: | t e |
        observe t
    finally:

// A break from a block in finally code in a loop in finally code.
test-break-in-nested-finally:
  x/any := 1
  try:
    try:
    finally:
      try:
      finally: | t e |
    a := :
      try:
      finally:
    b := :
    two a b
  finally:
    catch:
      try:
      finally:
        while budget:
          try:
            if pick:
              c := :
                if pick: break
              d := :
              two-finally c d
          finally: | t e |
      block := :
        observe x
      if pick: block.call

// The store is in a block in a loop in a block that is caught. The
// propagator didn't know the local could be null at the end, so the
// optimizer removed the code in 'observe' that checks for it.
test-store-in-caught-loop:
  x/any := 1
  a := :
    try:
      catch:
        block := :
          if pick:
            while budget:
              run:
                if pick: continue
                x = null
            try:
            finally: | t e |
        if pick: block.call
    finally: | t e |
    try:
    finally: | t e |
      observe x
  b := :
  two a b
  try:
  finally:

// A break in a loop in nested finally code, followed by a catch that uses
// a local from outside all of it.
test-catch-after-break-in-finally:
  x/any := 3.5
  block := :
    a := :
      if pick:
        c := :
        d := :
          try:
            try:
            finally: | t e |
          finally: | t e |
        two-finally c d
      else:
        try:
          c := :
          d := :
          two-finally c d
        finally:
          try:
          finally:
            while budget:
              try:
                if pick: break
              finally:
        catch:
          if x is float: observe x
    b := :
      c := :
      d := :
      two c d
    two a b
    try:
    finally:
  if pick: block.call

main:
  check ["string"] "TTFTT" --budget=8: test-loop-exit-sees-back-edge
  check ["true"] "T" --budget=2: test-continue-out-of-catch
  check ["null"] "TT" --budget=2: test-continue-then-later-code
  check ["false"] "TTT" --budget=2: test-finally-parameter-after-branches
  check ["int"] "TTT" --budget=2: test-break-in-nested-finally
  check ["null"] "TTTF" --budget=3: test-store-in-caught-loop
  check ["float"] "TFT" --budget=6: test-catch-after-break-in-finally
