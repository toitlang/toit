// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox
import encoding.base64

// The encoding module is not in the measured allowed set.
main args:
  sandbox-test args --error="PRIMITIVE_LOOKUP_FAILED": | arguments/Map |
    base64.encode #[1, 2, 3]
