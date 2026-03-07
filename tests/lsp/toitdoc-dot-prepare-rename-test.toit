// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: prepareRename with cursor on the method part of $Class.method in toitdoc.

/// See $Helper.compute for details.
/*
                ^
  compute
*/
class User:
  run:
    Helper.compute

class Helper:
  static compute:
    return 42

main:
  u := User
  u.run
