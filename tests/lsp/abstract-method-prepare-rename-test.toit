// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: abstract method declaration
abstract class Base:
  abstract my-abstract -> int
/*
           ^
  my-abstract
*/

class Impl extends Base:
  my-abstract -> int:
/*
  ^
  my-abstract
*/
    return 42

main:
  Impl
