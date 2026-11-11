// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .sandbox

// External and off-heap byte arrays are not in the untrusted set. An
// ordinary `ByteArray n` works for every n (large ones get an external
// backing store internally).
main args:
  sandbox-test args --error="PERMISSION_DENIED": | arguments/Map |
    expect-throw "PERMISSION_DENIED": create-off-heap-byte-array 1000
    ByteArray.external 1000
