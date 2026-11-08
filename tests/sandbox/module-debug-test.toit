// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The object histogram walks VM-wide data.
main args:
  sandbox-test args --error="PRIMITIVE_LOOKUP_FAILED": | arguments/Map |
    histogram_ "marker" 0

histogram_ marker full:
  #primitive.debug.object-histogram
