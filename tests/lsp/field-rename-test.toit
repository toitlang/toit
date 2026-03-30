// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a field should find definition and usages.
class Container:
  my-field := 0
/*@ def */
/*
  ^
  [def, getter, call]
*/

  read-it -> int:
    return my-field
/*         @ getter */
/*
           ^
  [def, getter, call]
*/

main:
  c := Container
  c.my-field
/*  @ call */
