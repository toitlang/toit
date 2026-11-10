// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The host name is host state.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    hostname_

hostname_:
  #primitive.core.hostname
