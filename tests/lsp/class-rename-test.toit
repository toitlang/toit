// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a class should find the definition and all usages.
class MyClass:
/*    ^
  3
*/
  field := 0

  member -> int:
    return field

make -> MyClass:
  return MyClass

main:
  obj := MyClass
/*       ^
  3
*/
  obj.member
