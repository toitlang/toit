// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Device primitives are denied (and not linked on the host).
main args:
  sandbox-test args --error="PRIMITIVE_LOOKUP_FAILED": | arguments/Map |
    ota-partition-name_

ota-partition-name_:
  #primitive.esp32.ota-current-partition-name
