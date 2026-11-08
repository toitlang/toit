// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// GC heuristics are VM-global.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    tune-memory-use_ 50

tune-memory-use_ percent/int:
  #primitive.core.tune-memory-use
