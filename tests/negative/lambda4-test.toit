// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

call-lambda should-call/bool fun/Lambda:
  if should-call: return fun.call
  return null

main:
  local ::= 499
  call-lambda true::
    local++
  unresolved
