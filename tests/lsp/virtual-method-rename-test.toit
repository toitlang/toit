// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a virtual method should find the definition and virtual call
// sites with matching name and shape.
//
// When the cursor is on the method definition, the rename should include:
//   - The definition itself.
//   - All virtual call sites with a matching selector and shape.
//
// Note: the FindReferencesPipeline runs after resolution but before
// type-checking, so placing the cursor on a virtual CALL site (as opposed
// to the definition) does not resolve a target. Those cases are tested
// via prepareRename instead.

class Animal:
  speak -> string:
/*
  ^
  4
*/
    return "..."

class Dog extends Animal:
  speak -> string:
/*
  ^
  4
*/
    return "woof"

call-it animal/Animal:
  animal.speak

main:
  dog := Dog
  dog.speak
  call-it dog
