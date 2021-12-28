// Copyright (C) 2020 Toitware ApS. All rights reserved.
// TEST_FLAGS: --force

foo optional/int=0:
bar --optional/int=0:

class A:
  field/int := ?

  constructor .field=0:
  constructor.named --.field=0:

null_string -> string?: return null

gee x/int:

null_only -> Null_: return null

main:
  foo null_string            // Error, even though null could match.
  bar --optional=null_string // Error, even though null could match.

  A null_string
  A.named --field=null_string

  a := A
  a = null

  gee null

  null_local := null  // No error. null-initialized local is of type any.
  gee null_local

  null_local2 := null_only
  gee null_local2
