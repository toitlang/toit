// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ...
import foo.
import ...  // comment
import foo. // comment
import ...  /* comment
  multiline */
import foo. /* comment
  multiline */

main:
  print unresolved
