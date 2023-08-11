// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
// TEST_FLAGS: --force

foo optional/int=0:
bar --optional/int=0:

class A:
  field/int := ?

  constructor .field=0:
  constructor.named --.field=0:

null-string -> string?: return null

gee x/int:

null-only -> Null_: return null

main:
  foo null-string            // Error, even though null could match.
  bar --optional=null-string // Error, even though null could match.

  A null-string
  A.named --field=null-string

  a := A
  a = null

  gee null

  null-local := null  // No error. null-initialized local is of type any.
  gee null-local

  null-local2 := null-only
  gee null-local2
