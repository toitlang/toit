// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import .ble-peripheral-security-nrf5340 as fixture

main:
  fixture.run --no-bonding --no-secure-connections --reject-pairing
