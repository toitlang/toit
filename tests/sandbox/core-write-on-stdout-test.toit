// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Writing to the VM's stdout directly is denied; print goes through
// the system print service instead.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    print_ "direct write"
