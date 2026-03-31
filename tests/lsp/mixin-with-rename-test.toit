// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a mixin from the with clause.
class Base:
  constructor:

mixin Mix:
/*    @ def */
  mix-method -> int:
    return 0

class Child extends Base with Mix:
/*
                              @ with-usage
                              ^
  [def, with-usage]
*/

main:
  Child
