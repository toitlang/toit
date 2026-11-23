// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bitmap
import .sandbox

main args:
  sandbox-test args --error="OUT_OF_RANGE" --quotas={"run-time-ms": 0, "cpu-ms": 10_000}: | arguments/Map |
    source := #[1]
    destination := ByteArray 1
    // The one-row allowance is 65,536 plus four times the combined lengths.
    bitmap.blit source destination 65_545
        --source-pixel-stride=0
        --destination-pixel-stride=0
        --source-line-stride=1
        --destination-line-stride=1
