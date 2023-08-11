// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo: return null
foo2= val:

class A:
  final-field ::= null

  bar:
    final-field = unresolved

  missing-getter= x: return null
  missing-setter: return null

  gee:
    missing-getter += unresolved
    missing-setter += unresolved

  foo= val:

  foo2: return 0

  toto:
    foo++
    foo2++

final-global ::= null

main:
  foo = unresolved
  A = unresolved
  b := (: null)
  b = unresolved
  non-block-local := null
  non-block-local = b
  (A).bar
  (A).gee
  (A).missing-getter += unresolved
  (A).missing-setter += unresolved
  final-local ::= null
  final-local = unresolved
  final-global = unresolved
  (A).toto
