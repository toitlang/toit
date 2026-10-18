// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

completes -> never:
  null

completes-on-some-paths flag/bool -> never:
  if flag: throw "x"

returns -> never:
  return

returns-value -> never:
  return 1

loop-with-break -> never:
  while true: break

not-a-parameter-type x/never:
  null

fail-with [block -> never] -> never:
  block.call

class Ui:
  abort msg/string -> never:
    throw msg

class BadUi extends Ui:
  abort msg/string -> none:
    print msg

interface Failer:
  fail -> never

class BadFailer implements Failer:
  fail -> int: return 0

unannotated-forever:
  while true: null

ret-int [block -> int] -> int: return block.call

main:
  local/never := throw "x"
  fail-with: 42
  y := ret-int: unannotated-forever
  unresolved
