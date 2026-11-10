// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The profiler changes the scheduler tick for the whole VM.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    profiler-install_ true

profiler-install_ all/bool:
  #primitive.core.profiler-install
