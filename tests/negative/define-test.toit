// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  field := null
  foo param:
    field := 499
    local := 42
    local.abs
    local.copy 1
    local := "String"
    local.abs
    local.copy 1
    param := 44
    unresolved

  constructor:
    field := unresolved

main:
  4 := 499
  (unresolved) ::= 42
  (A).foo 9
