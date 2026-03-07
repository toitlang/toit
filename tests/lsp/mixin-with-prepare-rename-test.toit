// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: mixin with clause
class Base:
  constructor:

mixin Mix:
  mix-method -> int:
    return 0

class Child extends Base with Mix:
/*
                              ^
  Mix
*/

main:
  Child
