// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a class at the show clause should rename the class everywhere.

import .show-clause-rename-test-dep show Visible
/*
                                         @ show
                                         ^
  [def, show, use]
*/

main:
  v := Visible
/*
       @ use
       ^
  [def, show, use]
*/
  print v.value
