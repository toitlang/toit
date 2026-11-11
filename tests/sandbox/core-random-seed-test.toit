// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .sandbox

// The PRNG can be used but not reseeded.
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    expect 0 <= (random 10) < 10
    set-random-seed "seed"
