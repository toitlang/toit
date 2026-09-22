// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import .vhci-reconnect as fixture

main:
  fixture.run --cycles=1000 --warmup=3 --numbered-cycles
