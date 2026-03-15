// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: member access
class Obj:
  my-method -> int:
    return 42

use-member:
  o := Obj
  o.my-method
/*
    ^
  my-method
*/

main:
  use-member
