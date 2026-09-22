// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.hci
import .vhci-central-provider as central

main: central.run Provider

class Provider extends central.Provider:
  constructor: super

  central-local-random-address info/hci.Capabilities -> ByteArray?:
    return #[2, 0x30, 0x23, 0xf2, 0x3a, 0xc8]
