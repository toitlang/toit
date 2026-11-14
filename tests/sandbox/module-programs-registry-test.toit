// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Starting containers from flash is denied (and PRIVILEGED).
main args:
  sandbox-test args --error="PRIMITIVE_LOOKUP_FAILED": | arguments/Map |
    registry-spawn_ 0 0 [] 1

registry-spawn_ offset gid arguments policy:
  #primitive.programs-registry.spawn
