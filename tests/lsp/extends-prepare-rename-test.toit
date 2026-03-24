// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: extends clause class name.
class Base:
  constructor:

class Child extends Base:
/*                  ^
  Base
*/
  constructor:

main:
  Child
