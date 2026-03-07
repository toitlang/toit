// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a class at the show clause should rename the class everywhere.

import .show-clause-rename-test-dep show Visible
/*
                                         ^
  3
*/

main:
  v := Visible
/*
       ^
  3
*/
  print v.value
