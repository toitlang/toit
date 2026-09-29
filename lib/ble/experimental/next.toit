// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
An experimental application API for the Toit BLE host.

Import it as `import ble.experimental.next as ble`. It runs where the BLE
  service runs: on controller-only firmware with a provider container, and
  on Linux through `ble.experimental.next.linux`. The design and its open
  questions are in `docs/ble/api.md`; the `ble` package keeps working beside
  it.
*/

import ble show BleUuid Advertisement DataBlock

import .next.adapter
import .next.connection
import .next.peripheral
import .next.types

export BleUuid Advertisement DataBlock
export *
