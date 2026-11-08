// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The hardware RNG is not in the measured allowed set.
main args:
  sandbox-test args --error="PRIMITIVE_LOOKUP_FAILED": | arguments/Map |
    crypto-random_ (ByteArray 16)

crypto-random_ bytes:
  #primitive.crypto-random.random
