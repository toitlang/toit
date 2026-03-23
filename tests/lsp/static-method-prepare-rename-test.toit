// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: static member access
class WithStatic:
  static my-static-method -> int:
    return 42

call-static:
  WithStatic.my-static-method
/*
             ^
  my-static-method
*/

main:
  call-static
