// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The host environment is not writable.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    set-env_ "TOIT_SANDBOX" "escaped"

set-env_ name/string value/string:
  #primitive.core.set-env
