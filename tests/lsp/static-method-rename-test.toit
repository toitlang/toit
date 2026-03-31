// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a static method should find definition and usages.
class WithStatic:
  static my-static -> int:
/*
         @ def
         ^
  [def, call]
*/
    return 42

call-it:
  return WithStatic.my-static
/*
                    @ call
                    ^
  [def, call]
*/

main:
  call-it
