// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Mapping the firmware (flash) is denied.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    firmware-map_ null

firmware-map_ data:
  #primitive.core.firmware-map
