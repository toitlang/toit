// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Dumping the heap reveals VM-wide information.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    dump-heap_ 0

dump-heap_ padding/int:
  #primitive.core.dump-heap
