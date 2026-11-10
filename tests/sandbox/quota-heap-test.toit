// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// Allocating beyond the heap quota fails inside the container.
main args:
  sandbox-test args --quotas={"heap": 2_000_000}: | arguments/Map |
    list := []
    while true: list.add (ByteArray 10_000)
