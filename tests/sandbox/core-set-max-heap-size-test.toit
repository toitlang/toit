// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The heap cap is installed by the launcher and can not be changed.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    set-max-heap-size_ 0

set-max-heap-size_ bytes/int:
  #primitive.core.set-max-heap-size
