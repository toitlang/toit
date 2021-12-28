// Copyright (C) 2020 Toitware ApS. All rights reserved.

call_lambda should_call/bool fun/Lambda:
  if should_call: return fun.call
  return null

main:
  local ::= 499
  call_lambda true::
    local++
  unresolved
