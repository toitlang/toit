// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: static constant in class declaration and usage
class Config:
  static MAX-SIZE ::= 100
/*
         ^
  MAX-SIZE
*/

  static get-max -> int:
    return MAX-SIZE
/*
           ^
  MAX-SIZE
*/

main:
  Config.get-max
