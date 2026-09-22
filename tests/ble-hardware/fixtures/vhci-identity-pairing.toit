// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import .vhci-pairing as fixture

main:
  // Exchanges a public fixture IRK; does not persist a local bond.
  fixture.run --exchange-identity
