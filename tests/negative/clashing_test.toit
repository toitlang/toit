// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  foo x:

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

  field_method := unresolved
  field_method: return unresolved

  field_static_method := unresolved
  static field_static_method: unresolved

  field_static_field := unresolved
  static field_static_field := unresolved

  constructor.named4: unresolved
  static named4: unresolved
  static named4 := unresolved

  static static_method_field: unresolved
  static static_method_field := unresolved

main:
  a := A
