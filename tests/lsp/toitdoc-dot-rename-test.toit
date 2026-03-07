// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a static method also updates $Class.method toitdoc references.

/// See $Helper.compute for details.
class User:
  run:
    Helper.compute

class Helper:
  static compute:
/*
         ^
  3
*/
    return 42

main:
  u := User
  u.run
