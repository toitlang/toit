// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a field should find definition and usages.
class Container:
  my-field := 0
/*
  ^
  3
*/

  read-it -> int:
    return my-field
/*
           ^
  3
*/

main:
  c := Container
  c.my-field
