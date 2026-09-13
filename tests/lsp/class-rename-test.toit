// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a class should find the definition and all usages.
class MyClass:
/*
      @ def
      ^
  [def, nullable, nullable-local, return-type, make-call, instantiation]
*/
  field := 0
  my-class/MyClass? := null
/*         @ nullable */

  member -> int:
    return field

make -> MyClass:
/*      @ return-type */
  return MyClass
/*       @ make-call */

main:
  obj := MyClass
/*
         @ instantiation
         ^
  [def, nullable, nullable-local, return-type, make-call, instantiation]
*/
  obj.member
  nullable-local/MyClass? := null
/*               @ nullable-local */
