// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..implementation_.service.darwin-provider show Provider

/**
Provides BLE through CoreBluetooth on macOS. Applications normally install
  it through ble.v2.darwin.open or ble.v2.darwin.install.

Methods whose names end in an underscore are internal SDK hooks.
*/

export Provider
