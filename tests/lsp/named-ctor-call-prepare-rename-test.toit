// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: named constructor at call site (not declaration site).
// Regression: cursor on "create" in "MyClass.create" used to resolve
// to the class "MyClass" instead of the constructor name "create".

class MyClass:
  field := 0
  constructor:
  constructor.create x:
    field = x

call-named-ctor:
  MyClass.create 42
/*
          ^
  create
*/

call-class:
  MyClass.create 42
/*
  ^
  MyClass
*/

main:
  call-named-ctor
  call-class
