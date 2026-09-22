// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import encoding.hex
import .vhci-multipeer as fixture

main:
  with-timeout --ms=60_000:
    fixture.run (hex.decode "98cdac63762e").reverse (hex.decode "84f703a00b3a").reverse
        --check-delay
