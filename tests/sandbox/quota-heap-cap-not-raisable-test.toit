// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// A trusted container with a heap quota can't raise its cap.
main args:
  sandbox-test args --trusted --quotas={"heap": 2_000_000}: | arguments/Map |
    set-max-heap-size_ 0
    list := []
    while true: list.add (ByteArray 10_000)

set-max-heap-size_ bytes/int:
  #primitive.core.set-max-heap-size
