// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import .ble-peer-esp32 as peer

main args/List:
  peer.run args --mtu=23
