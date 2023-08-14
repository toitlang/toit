// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  foo x: return 0

A := (A).foo unresolved

A:
  unresolved

class C:
  constructor x: unresolved
  constructor y: unresolved

  constructor.named: unresolved
  constructor.named: unresolved

  constructor.named2:
    unresolved
    return C 42
  constructor.named2:
    unresolved
    return C 499

  constructor.named3:
    unresolved
  constructor.named3:
    unresolved
    return C.named3

  static foo x: unresolved
  static foo y: unresolved

  static gee x: unresolved
  gee y: unresolved

  bar: unresolved
  bar: unresolved

  field-method := unresolved
  field-method: return unresolved

  field-static-method := unresolved
  static field-static-method: unresolved

  field-static-field := unresolved
  static field-static-field := unresolved

  constructor.named4: unresolved
  static named4: unresolved
  static named4 := unresolved

  static static-method-field: unresolved
  static static-method-field := unresolved

main:
  a := A
