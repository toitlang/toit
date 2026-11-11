// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Program introspection for debugging tools.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    literal-index_ "a literal"

literal-index_ object:
  #primitive.core.literal-index
