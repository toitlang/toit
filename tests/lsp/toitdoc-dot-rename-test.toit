// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a static method also updates $Class.method toitdoc references.

/// See $Helper.compute for details.
/*              @ toitdoc-ref */
class User:
  run:
    Helper.compute
/*         @ call */

class Helper:
  static compute:
/*
         @ def
         ^
  [def, call, toitdoc-ref]
*/
    return 42

main:
  u := User
  u.run
