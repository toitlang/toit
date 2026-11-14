// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The host environment is not readable.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    get-env_ "PATH"

get-env_ name/string:
  #primitive.core.get-env
