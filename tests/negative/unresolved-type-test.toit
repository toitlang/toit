// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  field /Unresolved := unresolved

  static static-field /Unresolved := unresolved

  foo -> Unresolved:
    return unresolved

  bar x/Unresolved?:
    return unresolved

  gee x/Unresolved? -> Unresolved:
    return unresolved

main:
  a := A
  a.field
  A.static-field
  a.foo
  a.bar null
  a.gee null
