// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .import_export1_a

main:
  foo  // Is a prefix in import_export1_a and should thus be unresolved, even though it's exported from import_export1_b
