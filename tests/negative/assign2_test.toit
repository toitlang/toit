// Copyright (C) 2019 Toitware ApS. All rights reserved.

foo: return null
foo2= val:

class A:
  final_field ::= null

  bar:
    final_field = unresolved

  missing_getter= x: return null
  missing_setter: return null

  gee:
    missing_getter += unresolved
    missing_setter += unresolved

  foo= val:

  foo2: return 0

  toto:
    foo++
    foo2++

final_global ::= null

main:
  foo = unresolved
  A = unresolved
  b := (: null)
  b = unresolved
  non_block_local := null
  non_block_local = b
  (A).bar
  (A).gee
  (A).missing_getter += unresolved
  (A).missing_setter += unresolved
  final_local ::= null
  final_local = unresolved
  final_global = unresolved
  (A).toto
