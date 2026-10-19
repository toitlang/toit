// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class Ui:
  abort msg/string -> never:
    throw msg

class LoudUi extends Ui:
  abort msg/string -> never:
    throw "LOUD: $msg"

interface Failer:
  fail -> never

class ThrowingFailer implements Failer:
  fail -> never: throw "failed"

fatal msg/string -> never:
  throw msg

forever -> never:
  while true: null

run-forever -> never:
  while true:
    while true: break  // Breaks out of the inner loop only.

ret-int [block -> int] -> int: return block.call

fail-with [block -> never] -> never:
  block.call

// No trailing `unreachable` needed.
abort-int ui/Ui -> int:
  ui.abort "abort-int"

abort-int-static -> int:
  fatal "abort-int-static"

abort-via-interface failer/Failer -> int:
  failer.fail

definite ui/Ui flag/bool -> int:
  x/int := ?
  if flag: x = 42
  else: ui.abort "definite"
  return x

merge flag/bool -> int:
  // The `if` has type 'int', since the other arm never completes.
  x := flag ? 1 : (fatal "merge")
  return x

main:
  ui := Ui
  expect-throw "abort-int": abort-int ui
  expect-throw "LOUD: abort-int": abort-int LoudUi
  expect-throw "abort-int-static": abort-int-static
  expect-throw "failed": abort-via-interface ThrowingFailer
  expect-equals 42 (definite ui true)
  expect-throw "definite": definite ui false
  expect-equals 1 (merge true)
  expect-throw "merge": merge false
  expect-throw "in block": fail-with: throw "in block"
  expect-throw "Unreachable": unreachable
  if false:
    x := ret-int: forever
    y := ret-int: run-forever
